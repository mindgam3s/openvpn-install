#!/bin/bash
#
# https://github.com/Nyr/openvpn-install
#
# Copyright (c) 2013 Nyr. Released under the MIT License.
#
# modified and refactored by: mindgam3s
# https://github.com/mindgam3s/openvpn-install
#

clientConfigPath="/var/www/html/"


################################################
## check_prereqs
################################################


# Detect Debian users running the script with "sh" instead of bash
if readlink /proc/$$/exe | grep -q "dash"; then
	echo 'This installer needs to be run with "bash", not "sh".'
	exit
fi

# Discard stdin. Needed when running from an one-liner which includes a newline
read -N 999999 -t 0.001

# Detect OpenVZ 6
if [[ $(uname -r | cut -d "." -f 1) -eq 2 ]]; then
	echo "The system is running an old kernel, which is incompatible with this installer."
	exit
fi

# Detect OS
# $os_version variables aren't always in use, but are kept here for convenience
if grep -qs "ubuntu" /etc/os-release; then
	os="ubuntu"
	os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
	group_name="nogroup"
elif [[ -e /etc/debian_version ]]; then
	os="debian"
	os_version=$(grep -oE '[0-9]+' /etc/debian_version | head -1)
	group_name="nogroup"
elif [[ -e /etc/almalinux-release || -e /etc/rocky-release || -e /etc/centos-release ]]; then
	os="centos"
	os_version=$(grep -shoE '[0-9]+' /etc/almalinux-release /etc/rocky-release /etc/centos-release | head -1)
	group_name="nobody"
elif [[ -e /etc/fedora-release ]]; then
	os="fedora"
	os_version=$(grep -oE '[0-9]+' /etc/fedora-release | head -1)
	group_name="nobody"
else
	echo "This installer seems to be running on an unsupported distribution.
Supported distros are Ubuntu, Debian, AlmaLinux, Rocky Linux, CentOS and Fedora."
	exit
fi

if [[ "$os" == "ubuntu" && "$os_version" -lt 1804 ]]; then
	echo "Ubuntu 18.04 or higher is required to use this installer.
This version of Ubuntu is too old and unsupported."
	exit
fi

if [[ "$os" == "debian" && "$os_version" -lt 9 ]]; then
	echo "Debian 9 or higher is required to use this installer.
This version of Debian is too old and unsupported."
	exit
fi

if [[ "$os" == "centos" && "$os_version" -lt 7 ]]; then
	echo "CentOS 7 or higher is required to use this installer.
This version of CentOS is too old and unsupported."
	exit
fi

# Detect environments where $PATH does not include the sbin directories
if ! grep -q sbin <<< "$PATH"; then
	echo '$PATH does not include sbin. Try using "su -" instead of "su".'
	exit
fi

if [[ "$EUID" -ne 0 ]]; then
	echo "This installer needs to be run with superuser privileges."
	exit
fi

if [[ ! -e /dev/net/tun ]] || ! ( exec 7<>/dev/net/tun ) 2>/dev/null; then
	echo "The system does not have the TUN device available.
TUN needs to be enabled before running this installer."
	exit
fi


################################################
################################################

ipv4_cidr_to_netmask() {
    value=$(( 0xffffffff ^ ((1 << (32 - $1)) - 1) ))
    echo "$(( (value >> 24) & 0xff )).$(( (value >> 16) & 0xff )).$(( (value >> 8) & 0xff )).$(( value & 0xff ))"
}

query_ipv4_address () {

	# If system has a single IPv4, it is selected automatically. Else, ask the user
	if [[ $(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}') -eq 1 ]]; then
		ipv4=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
	else
	number_of_ipv4=$(ip -4 addr | grep inet | grep -vEc '127(\.[0-9]{1,3}){3}')
	echo > /dev/stderr
	echo "Which IPv4 address should be used?" > /dev/stderr
	ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | nl -s ') '
	read -p "IPv4 address [1]: " ipv4_index
	until [[ -z "$ipv4_index" || "$ipv4_index" =~ ^[0-9]+$ && "$ipv4_index" -le "$number_of_ipv4" ]]; do
			echo "$ipv4_index: invalid selection." > /dev/stderr
			read -p "IPv4 address [1]: " ipv4_index
	done
	[[ -z "$ipv4_index" ]] && ipv4_index="1"
	ipv4=$(ip -4 addr | grep inet | grep -vE '127(\.[0-9]{1,3}){3}' | cut -d '/' -f 1 | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | sed -n "$ipv4_index"p)
	fi


	echo "$ipv4"
}

query_ipv6_address () {

	# If system has a single IPv6, it is selected automatically
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -eq 1 ]]; then
		ipv6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}')
	fi

	# If system has multiple IPv6, ask the user to select one
	if [[ $(ip -6 addr | grep -c 'inet6 [23]') -gt 1 ]]; then
		number_of_ipv6=$(ip -6 addr | grep -c 'inet6 [23]')
		echo > /dev/stderr
		echo "Which IPv6 address should be used?" > /dev/stderr
		ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | nl -s ') '
		read -p "IPv6 address [1]: " ipv6_index
		until [[ -z "$ipv6_index" || "$ipv6_index" =~ ^[0-9]+$ && "$ipv6_index" -le "$number_of_ipv6" ]]; do
					echo "$ipv6_index: invalid selection." > /dev/stderr
					read -p "IPv6 address [1]: " ipv6_index
		done
		[[ -z "$ipv6_index" ]] && ipv6_index="1"
		ipv6=$(ip -6 addr | grep 'inet6 [23]' | cut -d '/' -f 1 | grep -oE '([0-9a-fA-F]{0,4}:){1,7}[0-9a-fA-F]{0,4}' | sed -n "$ipv6_index"p)
	fi

	echo "$ipv6"
}



query_public_address () {

	ip="$1"

	# If $ip is a private IP address, the server must be behind NAT
	if echo "$ip" | grep -qE '^(10\.|172\.1[6789]\.|172\.2[0-9]\.|172\.3[01]\.|192\.168)'; then
		echo > /dev/stderr
		echo "This server is behind NAT. What is the public IPv4 address or hostname?" > /dev/stderr
		# Get public IP and sanitize with grep
		get_public_ip=$(grep -m 1 -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' <<< "$(wget -T 10 -t 1 -4qO- "http://ip1.dynupdate.no-ip.com/" || curl -m 10 -4Ls "http://ip1.dynupdate.no-ip.com/")")
		read -p "Public IPv4 address / hostname [$get_public_ip]: " public_ip
		# If the checkip service is unavailable and user didn't provide input, ask again
		until [[ -n "$get_public_ip" || -n "$public_ip" ]]; do
			echo "Invalid input." > /dev/stderr
			read -p "Public IPv4 address / hostname: " public_ip
		done
		[[ -z "$public_ip" ]] && public_ip="$get_public_ip"
	fi

	echo "$public_ip"

}


query_protocol () {
	echo > /dev/stderr
	echo "Which protocol should OpenVPN use?" > /dev/stderr
	echo "   1) UDP (recommended)" > /dev/stderr
	echo "   2) TCP" > /dev/stderr
	read -p "Protocol [2]: " protocol
	until [[ -z "$protocol" || "$protocol" =~ ^[12]$ ]]; do
			echo "$protocol: invalid selection." > /dev/stderr
			read -p "Protocol [2]: " protocol
	done
	case "$protocol" in
	1)
	protocol=udp
	;;
	2|"")
	protocol=tcp
	;;
	esac

	echo $protocol
}

query_port () {
	echo > /dev/stderr
	echo "What port should OpenVPN listen to?" > /dev/stderr
	read -p "Port [443]: " port
	until [[ -z "$port" || "$port" =~ ^[0-9]+$ && "$port" -le 65535 ]]; do
			echo "$port: invalid port." > /dev/stderr
			read -p "Port [443]: " port
	done
	[[ -z "$port" ]] && port="443"
	echo > /dev/stderr

	echo $port
}

query_dns () {
	echo > /dev/stderr
	echo "Select a DNS server for the clients:" > /dev/stderr
	echo "   1) Current system resolvers" > /dev/stderr
	echo "   2) Google" > /dev/stderr
	echo "   3) 1.1.1.1" > /dev/stderr
	echo "   4) OpenDNS" > /dev/stderr
	echo "   5) Quad9" > /dev/stderr
	echo "   6) AdGuard" > /dev/stderr
	read -p "DNS server [1]: " dns_option
	until [[ -z "$dns_option" || "$dns_option" =~ ^[1-6]$ ]]; do
		echo "$dns_option: invalid selection."
		read -p "DNS server [1]: " dns_option
	done
	[[ -z "$dns_option" ]] && dns_option="1"

	echo $dns_option
}

build_certificate_authority () {

	easy_rsa_url='https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.0/EasyRSA-3.1.0.tgz'

	mkdir -p /etc/openvpn/server/easy-rsa/ >/dev/null
	{ wget -qO- "$easy_rsa_url" 2>/dev/null || curl -sL "$easy_rsa_url" ; } | tar xz -C /etc/openvpn/server/easy-rsa/ --strip-components 1 >/dev/null
	chown -R root:root /etc/openvpn/server/easy-rsa/ >/dev/null

	pushd /etc/openvpn/server/easy-rsa/ >/dev/null

	# Create the PKI, set up the CA and the server and client certificates
	EASYRSA_BATCH=1 ./easyrsa init-pki >/dev/null
	EASYRSA_BATCH=1 ./easyrsa --batch --req-cn="hummler" build-ca nopass >/dev/null

	EASYRSA_BATCH=1 EASYRSA_CERT_EXPIRE=3650 ./easyrsa build-server-full server nopass >/dev/null
	EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl >/dev/null

	popd &>/dev/null
}

prepare_important_files () {

	pushd /etc/openvpn/server/easy-rsa/

	# Move the stuff we need
	cp pki/ca.crt pki/private/ca.key pki/issued/server.crt pki/private/server.key pki/crl.pem /etc/openvpn/server >/dev/null
	# CRL is read with each client connection, while OpenVPN is dropped to nobody
	chown nobody:"$group_name" /etc/openvpn/server/crl.pem >/dev/null
	# Without +x in the directory, OpenVPN can't run a stat() on the CRL file
	chmod o+x /etc/openvpn/server/ >/dev/null
	# Generate key for tls-crypt
	openvpn --genkey secret /etc/openvpn/server/tc.key >/dev/null

	popd &>/dev/null
}

generate_diffie_hellman_file () {
	# Create the DH parameters file using the predefined ffdhe2048 group
	# see https://security.stackexchange.com/a/149818
	# and https://www.rfc-editor.org/rfc/rfc7919
	echo '-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA//////////+t+FRYortKmq/cViAnPTzx2LnFg84tNpWp4TZBFGQz
+8yTnc4kmz75fS/jY2MMddj2gbICrsRhetPfHtXV/WVhJDP1H18GbtCFY2VVPe0a
87VXE15/V8k1mE8McODmi3fipona8+/och3xWKE2rec1MKzKT0g6eXq8CrGCsyT7
YdEIqUuyyOP7uWrat2DX9GgdT0Kj3jlN9K5W7edjcrsZCwenyO4KbXCeAvzhzffi
7MA0BM0oNC9hkXL+nOmFg/+OTxIy7vKBg8P+OxtMb61zO7X8vC7CIAXFjvGDfRaD
ssbzSibBsu/6iGtCOGEoXJf//////////wIBAg==
-----END DH PARAMETERS-----' > /etc/openvpn/server/dh.pem
}

generate_server_config_file () {

	protocol="$1"
	port="$2"
	dns_option="$3"
	ipv4="$4"
	ipv6="$5"
	public_address="$6"


	# Generate server.conf
   echo "local $ipv4
port $port
proto $protocol
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
auth SHA512
tls-crypt tc.key
topology subnet
server 10.8.0.0 255.255.255.0" > /etc/openvpn/server/server.conf

	# IPv6
	if [[ -z "$ipv6" ]]; then
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	else
  		echo 'server-ipv6 fddd:1194:1194:1194::/64' >> /etc/openvpn/server/server.conf
		echo 'push "redirect-gateway def1 bypass-dhcp"' >> /etc/openvpn/server/server.conf
  		echo 'push "redirect-gateway def1 ipv6 bypass-dhcp"' >> /etc/openvpn/server/server.conf
	fi

	echo 'ifconfig-pool-persist ipp.txt' >> /etc/openvpn/server/server.conf


	# DNS
	case "$dns_option" in
	1|"")
		# Locate the proper resolv.conf
		# Needed for systems running systemd-resolved
		if grep '^nameserver' "/etc/resolv.conf" | grep -qv '127.0.0.53' ; then
		resolv_conf="/etc/resolv.conf"
		else
		resolv_conf="/run/systemd/resolve/resolv.conf"
		fi
		# Obtain the resolvers from resolv.conf and use them for OpenVPN
		grep -v '^#\|^;' "$resolv_conf" | grep '^nameserver' | grep -v '127.0.0.53' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' | while read line; do
					echo "push \"dhcp-option DNS $line\"" >> /etc/openvpn/server/server.conf
		done

		grep -v '^#\|^;' "$resolv_conf" | grep '^search' | grep -oP '(?<=search ).*' | while read line; do
					echo "push \"dhcp-option DOMAIN $line\"" >> /etc/openvpn/server/server.conf
		done

                # TESTING check this later
		# should add a 'push "route 192.168.0.0 255.255.255.0"' entry to resolve internal ip adresses correctly
		ip route show | grep '[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*/[0-9]*' | grep -v '^10\.' | grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){2}\.0' | while read line; do
					echo "push \"dhcp-option route $line 255.255.255.0\"" >> /etc/openvpn/server/server.conf
		done

	;;
	2)
		echo 'push "dhcp-option DNS 8.8.8.8"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 8.8.4.4"' >> /etc/openvpn/server/server.conf
	;;
	3)
		echo 'push "dhcp-option DNS 1.1.1.1"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 1.0.0.1"' >> /etc/openvpn/server/server.conf
	;;
	4)
		echo 'push "dhcp-option DNS 208.67.222.222"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 208.67.220.220"' >> /etc/openvpn/server/server.conf
	;;
	5)
		echo 'push "dhcp-option DNS 9.9.9.9"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 149.112.112.112"' >> /etc/openvpn/server/server.conf
	;;
	6)
		echo 'push "dhcp-option DNS 94.140.14.14"' >> /etc/openvpn/server/server.conf
		echo 'push "dhcp-option DNS 94.140.15.15"' >> /etc/openvpn/server/server.conf
	;;
	esac

	echo 'push "block-outside-dns"' >> /etc/openvpn/server/server.conf


	if [[ -z "$ipv6" ]]; then
		echo 'push "route 0.0.0.0 0.0.0.0 vpn_gateway"' >> /etc/openvpn/server/server.conf
	else
  		echo 'push "route 0.0.0.0 0.0.0.0 vpn_gateway"' >> /etc/openvpn/server/server.conf
    		echo 'push "route-ipv6 ::/0 vpn_gateway"' >> /etc/openvpn/server/server.conf
	fi
 
	

	echo "keepalive 10 120
user nobody
group $group_name
persist-key
persist-tun
verb 3
crl-verify crl.pem" >> /etc/openvpn/server/server.conf

	if [[ "$protocol" = "udp" ]]; then
	echo "explicit-exit-notify" >> /etc/openvpn/server/server.conf
	fi

	# Enable net.ipv4.ip_forward for the system
	echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-openvpn-forward.conf

	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv4/ip_forward

	if [[ -n "$ipv6" ]]; then
	# Enable net.ipv6.conf.all.forwarding for the system
	echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.d/99-openvpn-forward.conf

	# Enable without waiting for a reboot or service restart
	echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
	fi


	if systemctl is-active --quiet firewalld.service; then
	# Using both permanent and not permanent rules to avoid a firewalld
	# reload.
	# We don't use --add-service=openvpn because that would only work with
	# the default port and protocol.
	firewall-cmd --add-port="$port"/"$protocol"
	firewall-cmd --zone=trusted --add-source=10.8.0.0/24
	firewall-cmd --permanent --add-port="$port"/"$protocol"
	firewall-cmd --permanent --zone=trusted --add-source=10.8.0.0/24
	# Set NAT for the VPN subnet
	firewall-cmd --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ipv4"
	firewall-cmd --permanent --direct --add-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ipv4"
	if [[ -n "$ipv6" ]]; then
		firewall-cmd --zone=trusted --add-source=fddd:1194:1194:1194::/64
		firewall-cmd --permanent --zone=trusted --add-source=fddd:1194:1194:1194::/64
		firewall-cmd --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ipv6"
		firewall-cmd --permanent --direct --add-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ipv6"
	fi
	else
	# Create a service to set up persistent iptables rules
	iptables_path=$(command -v iptables)
	ip6tables_path=$(command -v ip6tables)
	# nf_tables is not available as standard in OVZ kernels. So use iptables-legacy
	# if we are in OVZ, with a nf_tables backend and iptables-legacy is available.
	if [[ $(systemd-detect-virt) == "openvz" ]] && readlink -f "$(command -v iptables)" | grep -q "nft" && hash iptables-legacy 2>/dev/null; then
		iptables_path=$(command -v iptables-legacy)
		ip6tables_path=$(command -v ip6tables-legacy)
	fi

	echo "[Unit]
Before=network.target
[Service]
Type=oneshot
ExecStart=$iptables_path -t nat -A POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ipv4
ExecStart=$iptables_path -I INPUT -p $protocol --dport $port -j ACCEPT
ExecStart=$iptables_path -I FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStart=$iptables_path -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$iptables_path -t nat -D POSTROUTING -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to $ipv4
ExecStop=$iptables_path -D INPUT -p $protocol --dport $port -j ACCEPT
ExecStop=$iptables_path -D FORWARD -s 10.8.0.0/24 -j ACCEPT
ExecStop=$iptables_path -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" > /etc/systemd/system/openvpn-iptables.service
	if [[ -n "$ipv6" ]]; then
		echo "ExecStart=$ip6tables_path -t nat -A POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ipv6
ExecStart=$ip6tables_path -I FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStart=$ip6tables_path -I FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
ExecStop=$ip6tables_path -t nat -D POSTROUTING -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to $ipv6
ExecStop=$ip6tables_path -D FORWARD -s fddd:1194:1194:1194::/64 -j ACCEPT
ExecStop=$ip6tables_path -D FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT" >> /etc/systemd/system/openvpn-iptables.service
	fi

	echo "RemainAfterExit=yes
[Install]
WantedBy=multi-user.target" >> /etc/systemd/system/openvpn-iptables.service

	systemctl enable --now openvpn-iptables.service
	fi

	# If SELinux is enabled and a custom port was selected, we need this
	if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
	# Install semanage if not already present
	if ! hash semanage 2>/dev/null; then
		if [[ "$os_version" -eq 7 ]]; then
		# Centos 7
		yum install -y policycoreutils-python
		else
		# CentOS 8 or Fedora
		dnf install -y policycoreutils-python-utils
		fi
	fi
	semanage port -a -t openvpn_port_t -p "$protocol" "$port"
	fi

	# If the server is behind NAT, use the correct IP address
	[[ -n "$ipv4" ]] && ip="$ipv4"

	# client-common.txt is created so we have a template to add further users later
}

generate_client_template_file () {

	protocol="$1"
	port="$2"
	public_address="$3"


	echo "client
dev tun
proto $protocol
remote $public_address $port
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA512
ignore-unknown-option block-outside-dns
verb 3" > /etc/openvpn/server/client-common.txt
}

generate_client_config () {

	client_path="$1"
	unsanitized_client_name="$2"

	client_name=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client_name")

	pushd /etc/openvpn/server/easy-rsa/

	EASYRSA_BATCH=1 ./easyrsa --batch --days=3650 build-client-full "${client_name}" nopass &>/dev/null


	# Generates the custom client.ovpn
	{
		cat /etc/openvpn/server/client-common.txt
		echo "<ca>"
		cat /etc/openvpn/server/easy-rsa/pki/ca.crt
		echo "</ca>"
		echo "<cert>"
		sed -ne '/BEGIN CERTIFICATE/,$ p' /etc/openvpn/server/easy-rsa/pki/issued/"${client_name}".crt
		echo "</cert>"
		echo "<key>"
		cat /etc/openvpn/server/easy-rsa/pki/private/"${client_name}".key
		echo "</key>"
		echo "<tls-crypt>"
		sed -ne '/BEGIN OpenVPN Static key/,$ p' /etc/openvpn/server/tc.key
		echo "</tls-crypt>"
	} > "${client_path}${client_name}".ovpn

	echo "The client configuration is available in:" "${client_path}${client_name}.ovpn" > /dev/stderr

	popd &>/dev/null
}


################################################
## MAIN
################################################


if [[ ! -e /etc/openvpn/server/server.conf ]]; then

	build_certificate_authority

	echo "OpenVPN installation is ready to begin."
	# Install a firewall if firewalld or iptables are not already available
	if ! systemctl is-active --quiet firewalld.service && ! hash iptables 2>/dev/null; then
		if [[ "$os" == "centos" || "$os" == "fedora" ]]; then
			firewall="firewalld"
			# We don't want to silently enable firewalld, so we give a subtle warning
			# If the user continues, firewalld will be installed and enabled during setup
			echo "firewalld, which is required to manage routing tables, will also be installed."
		elif [[ "$os" == "debian" || "$os" == "ubuntu" ]]; then
			# iptables is way less invasive than firewalld so no warning is given
			firewall="iptables"
		fi
	fi
	read -n1 -r -p "Press any key to continue..."
	# If running inside a container, disable LimitNPROC to prevent conflicts
	if systemd-detect-virt -cq; then
		mkdir /etc/systemd/system/openvpn-server@server.service.d/ 2>/dev/null
		echo "[Service]
LimitNPROC=infinity" > /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
	fi
	if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
		apt-get update
		apt-get install -y openvpn openssl ca-certificates $firewall
	elif [[ "$os" = "centos" ]]; then
		yum install -y epel-release
		yum install -y openvpn openssl ca-certificates tar $firewall
	else
		# Else, OS must be Fedora
		dnf install -y openvpn openssl ca-certificates tar $firewall
	fi
	# If firewalld was just installed, enable it
	if [[ "$firewall" == "firewalld" ]]; then
		systemctl enable --now firewalld.service
	fi


	prepare_important_files
	generate_diffie_hellman_file

	protocol=`query_protocol`
	port=`query_port`
	ipv4=`query_ipv4_address`
	ipv6=`query_ipv6_address`

	public_address=`query_public_address "$ipv4"`

	dns_option=`query_dns`


	generate_server_config_file $protocol $port $dns_option $ipv4 $ipv6 $public_address

	generate_client_template_file $protocol $port $public_address

	# Enable and start the OpenVPN service
	systemctl enable --now openvpn-server@server.service

	echo "FINISHED!"

else

	echo "OpenVPN is already installed."
	echo
	echo "Select an option:"
	echo "   1) Add a new client"
	echo "   2) Re-generate an existing client's config file (.ovpn)"
	echo "   3) Revoke an existing client"
	echo "   4) Remove OpenVPN"
	echo "   5) Exit"
	read -p "Option: " option
	until [[ "$option" =~ ^[1-4]$ ]]; do
			echo "$option: invalid selection."
			read -p "Option: " option
	done
	case "$option" in
	1)
		echo
		echo "Provide a name for the client:"
		read -p "Name: " unsanitized_client
		client_name=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
		while [[ -z "$client_name" || -e /etc/openvpn/server/easy-rsa/pki/issued/"${client_name}".crt ]]; do
					echo "$client_name: invalid name."
					read -p "Name: " unsanitized_client
					client_name=$(sed 's/[^0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-]/_/g' <<< "$unsanitized_client")
		done

		# Generates the custom client.ovpn
		generate_client_config "${clientConfigPath}" "${client_name}"

		popd &>/dev/null
		exit
	;;

	2)
		# This option could be documented a bit better and maybe even be simplified
		# ...but what can I say, I want some sleep too
		number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
		if [[ "$number_of_clients" = 0 ]]; then
		echo
		echo "There are no existing clients!"
		exit
		fi
		echo
		echo "Select the client config to be re-generated:"
		tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
		read -p "Client: " client_number
		until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
					echo "$client_number: invalid selection."
					read -p "Client: " client_number
		done
		client_name=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
		echo
		read -p "Confirm '${client_name}' config file re-generation? [y/N]: " regen
		until [[ "$regen" =~ ^[yYnN]*$ ]]; do
					echo "$regen: invalid selection."
					read -p "Confirm '${client_name}' config file re-generation? [y/N]: " regen
		done
		if [[ "$regen" =~ ^[yY]$ ]]; then
		##
		generate_client_config "${clientConfigPath}" "${client_name}"
		##
		echo
		echo "'${client_name}' config file re-generated!"
		else
		echo
		echo "'${client_name}' config file re-generation aborted!"
		fi
		exit
	;;

	3)
		# This option could be documented a bit better and maybe even be simplified
		# ...but what can I say, I want some sleep too
		number_of_clients=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep -c "^V")
		if [[ "$number_of_clients" = 0 ]]; then
		echo
		echo "There are no existing clients!"
		exit
		fi
		echo
		echo "Select the client to revoke:"
		tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | nl -s ') '
		read -p "Client: " client_number
		until [[ "$client_number" =~ ^[0-9]+$ && "$client_number" -le "$number_of_clients" ]]; do
					echo "$client_number: invalid selection."
					read -p "Client: " client_number
		done
		client_name=$(tail -n +2 /etc/openvpn/server/easy-rsa/pki/index.txt | grep "^V" | cut -d '=' -f 2 | sed -n "$client_number"p)
		echo
		read -p "Confirm '${client_name}' revocation? [y/N]: " revoke
		until [[ "$revoke" =~ ^[yYnN]*$ ]]; do
					echo "$revoke: invalid selection."
					read -p "Confirm '${client_name}' revocation? [y/N]: " revoke
		done
		if [[ "$revoke" =~ ^[yY]$ ]]; then
		pushd /etc/openvpn/server/easy-rsa/

		EASYRSA_BATCH=1 ./easyrsa --batch revoke "${client_name}"
		EASYRSA_BATCH=1 EASYRSA_CRL_DAYS=3650 ./easyrsa gen-crl
		rm -f /etc/openvpn/server/crl.pem
		cp /etc/openvpn/server/easy-rsa/pki/crl.pem /etc/openvpn/server/crl.pem
		# CRL is read with each client connection, when OpenVPN is dropped to nobody
		chown nobody:"$group_name" /etc/openvpn/server/crl.pem
		echo
		echo "'${client_name}' revoked!"

		popd &>/dev/null
		else
		echo
		echo "'${client_name}' revocation aborted!"
		fi

		exit
	;;

	4)
		echo
		read -p "Confirm OpenVPN removal? [y/N]: " remove
		until [[ "$remove" =~ ^[yYnN]*$ ]]; do
					echo "$remove: invalid selection."
					read -p "Confirm OpenVPN removal? [y/N]: " remove
		done
		if [[ "$remove" =~ ^[yY]$ ]]; then
		port=$(grep '^port ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
		protocol=$(grep '^proto ' /etc/openvpn/server/server.conf | cut -d " " -f 2)
		if systemctl is-active --quiet firewalld.service; then
			ip=$(firewall-cmd --direct --get-rules ipv4 nat POSTROUTING | grep '\-s 10.8.0.0/24 '"'"'!'"'"' -d 10.8.0.0/24' | grep -oE '[^ ]+$')
			# Using both permanent and not permanent rules to avoid a firewalld reload.
			firewall-cmd --remove-port="$port"/"$protocol"
			firewall-cmd --zone=trusted --remove-source=10.8.0.0/24
			firewall-cmd --permanent --remove-port="$port"/"$protocol"
			firewall-cmd --permanent --zone=trusted --remove-source=10.8.0.0/24
			firewall-cmd --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
			firewall-cmd --permanent --direct --remove-rule ipv4 nat POSTROUTING 0 -s 10.8.0.0/24 ! -d 10.8.0.0/24 -j SNAT --to "$ip"
			if grep -qs "server-ipv6" /etc/openvpn/server/server.conf; then
			ipv6=$(firewall-cmd --direct --get-rules ipv6 nat POSTROUTING | grep '\-s fddd:1194:1194:1194::/64 '"'"'!'"'"' -d fddd:1194:1194:1194::/64' | grep -oE '[^ ]+$')
			firewall-cmd --zone=trusted --remove-source=fddd:1194:1194:1194::/64
			firewall-cmd --permanent --zone=trusted --remove-source=fddd:1194:1194:1194::/64
			firewall-cmd --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ipv6"
			firewall-cmd --permanent --direct --remove-rule ipv6 nat POSTROUTING 0 -s fddd:1194:1194:1194::/64 ! -d fddd:1194:1194:1194::/64 -j SNAT --to "$ipv6"
			fi
		else
			systemctl disable --now openvpn-iptables.service
			rm -f /etc/systemd/system/openvpn-iptables.service
		fi
		if sestatus 2>/dev/null | grep "Current mode" | grep -q "enforcing" && [[ "$port" != 1194 ]]; then
			semanage port -d -t openvpn_port_t -p "$protocol" "$port"
		fi
		systemctl disable --now openvpn-server@server.service
		rm -f /etc/systemd/system/openvpn-server@server.service.d/disable-limitnproc.conf
		rm -f /etc/sysctl.d/99-openvpn-forward.conf
		if [[ "$os" = "debian" || "$os" = "ubuntu" ]]; then
			rm -rf /etc/openvpn/server
			apt-get remove --purge -y openvpn
		else
			# Else, OS must be CentOS or Fedora
			yum remove -y openvpn
			rm -rf /etc/openvpn/server
		fi
		echo
		echo "OpenVPN removed!"
		else
		echo
		echo "OpenVPN removal aborted!"
		fi

		exit
	;;

	5)
		exit
	;;
	esac

fi
