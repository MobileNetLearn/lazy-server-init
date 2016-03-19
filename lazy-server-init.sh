#!/bin/bash

# lazy-server-init
# Do all the stuff I'm too lazy to do when I'm running a new server.
# check comments for more info -- only tested with Debian 8 (Jessie)(64 bits)

# check for root
if [[ $EUID -ne 0 ]]
then
	echo "Sorry dude, you must be logged as root to run this script."
	echo "Anyway, it should not be used if the server is already configured."
	exit 1
fi

#################
# System update #
#################

# change root password
read -p "Change root password? (Y/n) " ISROOTPWD
ISROOTPWD="${ISROOTPWD:-y}"
if [[ $ISROOTPWD =~ ^[Yy]$ ]]
then
	passwd
fi

# plan a weekly update 
echo "Planning a weekly system update..."
cat > /etc/cron.weekly/apt-update <<- _EOF
	#!/bin/sh
	apt-get -y update
	apt-get -y upgrade
	apt-get -y autoremove
	apt-get -y autoclean
_EOF
chmod +x /etc/cron.weekly/apt-update
# update system
/etc/cron.weekly/apt-update

#######
# SSH #
#######

echo "Configuring SSH..."
# create a new user for SSH
echo "Creating a new user, SSH root login will be disabled."
read -e -p "Enter username: " USERNAME
adduser $USERNAME
# create the group ssh-users and affect the new user to this group
addgroup ssh-users
usermod -a -G ssh-users $USERNAME
# prepare sshd_config file
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
echo >> /etc/ssh/sshd_config
echo >> /etc/ssh/sshd_config
# set SSH port
read -e -p "Enter SSH port: " SSHPORT
sed -e '/Port 22/ s/^#*/#/' -i /etc/ssh/sshd_config
echo 'Port' $SSHPORT >> /etc/ssh/sshd_config
# disable root login
sed -e '/PermitRootLogin/ s/^#*/#/' -i /etc/ssh/sshd_config
echo 'PermitRootLogin no' >> /etc/ssh/sshd_config
# enable SSH for the group ssh-users only
sed -e '/AllowGroups/ s/^#*/#/' -i /etc/ssh/sshd_config
echo 'AllowGroups ssh-users' >> /etc/ssh/sshd_config
/etc/init.d/ssh restart

############
# IPTABLES #
############

echo "Initializing iptables..."
apt-get install iptables
# create a light, non-bulletproof iptables configuration
# will be launched at startup
cat > /etc/network/if-pre-up.d/iptables <<- _EOF
	#!/bin/sh
	# clean current rules
	iptables -t filter -F 
	iptables -t filter -X 
	# block all the trafic except for output chain
	iptables -t filter -P INPUT DROP 
	iptables -t filter -P FORWARD DROP 
	iptables -t filter -P OUTPUT ACCEPT 
	# allow already etablished connections
	iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
	# allow loopback
	iptables -t filter -A INPUT -i lo -j ACCEPT
	# allow ping
	iptables -t filter -A INPUT -p icmp -j ACCEPT 
	# allow SSH
	iptables -t filter -A INPUT -p tcp --dport ${SSHPORT} -j ACCEPT
_EOF
chmod +x /etc/network/if-pre-up.d/iptables
# execute the rules now
/etc/network/if-pre-up.d/iptables

############
# FAIL2BAN #
############

read -p "Install fail2ban? (Y/n) " ISF2B
ISF2B="${ISF2B:-y}"
if [[ $ISF2B =~ ^[Yy]$ ]]
then
	echo "Installing fail2ban..."
	apt-get install -y fail2ban
	cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
	# enable for SSH
	sed -re "/^\[ssh\]$/,/^\[/s/enabled[[:blank:]]*=.*/enabled = true/" -i /etc/fail2ban/jail.local
	sed -re "/^\[ssh\]$/,/^\[/s/port[[:blank:]]*=.*/port = $SSHPORT/" -i /etc/fail2ban/jail.local
	sed -re "/^\[ssh-ddos\]$/,/^\[/s/enabled[[:blank:]]*=.*/enabled = true/" -i /etc/fail2ban/jail.local
	sed -re "/^\[ssh-ddos\]$/,/^\[/s/port[[:blank:]]*=.*/port = $SSHPORT/" -i /etc/fail2ban/jail.local
	/etc/init.d/fail2ban restart
fi

###############
# UNBOUND DNS #
###############

read -p "Install a private local DNS server (Unbound)? (Y/n) " ISDNS
ISDNS="${ISDNS:-y}" 
if [[ $ISDNS =~ ^[Yy]$ ]]
then
	# install Unbound DNS server
	echo "Installing Unbound DNS server..."
	apt-get install -y unbound
	wget ftp://FTP.INTERNIC.NET/domain/named.cache -O /var/lib/unbound/root.hints
	mv /etc/unbound/unbound.conf /etc/unbound/unbound.conf.backup
	# init the configuration file for a local use
	cat > /etc/unbound/unbound.conf <<- _EOF
		# check https://www.unbound.net/documentation/unbound.conf.html for documentation
		server:
		auto-trust-anchor-file: "/var/lib/unbound/root.key"
		verbosity: 1
		interface: 0.0.0.0
		port: 53
		do-ip4: yes
		do-ip6: yes
		do-udp: yes
		do-tcp: yes
		access-control: 127.0.0.0/8 allow
		access-control: 10.8.0.0/8 allow
		root-hints: "/var/lib/unbound/root.hints"
		hide-identity: yes
		hide-version: yes
		harden-glue: yes
		harden-dnssec-stripped: yes
		use-caps-for-id: yes
		cache-min-ttl: 3600
		cache-max-ttl: 86400
		prefetch: yes
		private-address: 127.0.0.0/8
		private-address: 10.8.0.0/8
		unwanted-reply-threshold: 10000
	_EOF
	# set the local DNS server as main DNS
	sed -e '/nameserver/ s/^#*/#/' -i /etc/resolv.conf
	echo 'nameserver 127.0.0.1' >> /etc/resolv.conf
	IP="`wget -q -O - ident.me`"
	echo 'nameserver' $IP >> /etc/resolv.conf
	# lock the file in order to not be changed after reboot (chattr -i /etc/resolv.conf to unlock)
	chattr +i /etc/resolv.conf
	/etc/init.d/unbound restart
fi

###########
# OPENVPN #
###########

read -p "Install OpenVPN server? (Y/n) " ISVPN
ISVPN="${ISVPN:-y}"
if [[ $ISVPN =~ ^[Yy]$ ]]
then
	# install and configure OpenVPN Server using the awsome Nyr script (https://github.com/Nyr/openvpn-install)
	echo "Installing OpenVPN server..."
	wget git.io/vpn --no-check-certificate -O openvpn-install.sh
	bash openvpn-install.sh
	if [[ $ISDNS =~ ^[Yy]$ ]]
	then
		# set the local DNS server as main DNS
		echo "Setting the local DNS server as main DNS for OpenVPN..."
		sed -e '/dhcp-option DNS/ s/^#*/#/' -i /etc/openvpn/server.conf
		echo 'push "dhcp-option DNS 10.8.0.1"' >> /etc/openvpn/server.conf
	fi
	read -p "Disable OpenVPN server logs? (Y/n) " ISNVPNLOG
	ISNVPNLOG="${ISNVPNLOG:-y}"
	if [[ $ISNVPNLOG =~ ^[Yy]$ ]]
	then
		# disable logging
		echo "Disabling OpenVPN logging..."
		echo 'log /dev/null' >> /etc/openvpn/server.conf
		echo 'status /dev/null' >> /etc/openvpn/server.conf
		sed -e '/verb / s/^#*/#/' -i /etc/openvpn/server.conf
		echo 'verb 0' >> /etc/openvpn/server.conf
	fi
	/etc/init.d/openvpn restart
	# update iptables
	echo "Adding iptables rules..."
	OVPNPORT=$(grep '^port ' /etc/openvpn/server.conf | cut -d " " -f 2)
	cat >> /etc/network/if-pre-up.d/iptables <<- _EOF
		# Allow OpenVPN
		iptables -t filter -A INPUT -p udp --dport ${OVPNPORT} -j ACCEPT
		iptables -A INPUT -i tun+ -j ACCEPT
		iptables -A FORWARD -i tun+ -j ACCEPT
		iptables -A FORWARD -i tun+ -o eth0 -m state --state RELATED,ESTABLISHED -j ACCEPT
		iptables -A FORWARD -i eth0 -o tun+ -m state --state RELATED,ESTABLISHED -j ACCEPT
		iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
	_EOF
	# appy rules
	/etc/network/if-pre-up.d/iptables
	if [[ $ISF2B =~ ^[Yy]$ ]]
	then
		# re-apply fail2ban rules
		/etc/init.d/fail2ban restart
	fi
fi

echo "******** The End ********"