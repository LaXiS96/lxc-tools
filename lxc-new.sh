#!/bin/bash
# If no release and arch arguments are passed, Ubuntu trusty amd64 is assumed

if [ "$(id -u)" != "0" ]; then
  echo "Please run me as superuser!" 1>&2
  exit 1
fi

while [ $# -gt 1 ]; do
  case $1 in
    -n|--name) CONTAINER_NAME="$2"; shift;;
    -a|--address) CONTAINER_ADDRESS="$2"; shift;;
    -g|--gateway) CONTAINER_GATEWAY="$2"; shift;;
    -r|--release) CONTAINER_RELEASE="$2"; shift;;
    -c|--arch) CONTAINER_ARCH="$2"; shift;;
  esac
  shift
done

if [ -z "$CONTAINER_NAME" ]; then
  echo "FATAL: missing container name. (specify with -n <name>)"; exit 1
fi
if [ -z "$CONTAINER_ADDRESS" ]; then
  echo "FATAL: missing container address. (specify with -a <#.#.#.#>)"; exit 1
fi
if [ -z "$CONTAINER_GATEWAY" ]; then
  echo "FATAL: missing container gateway. (specify with -g <#.#.#.#>)"; exit 1
fi
if [ -z "$CONTAINER_RELEASE" ]; then
  CONTAINER_RELEASE="trusty"
fi
if [ -z "$CONTAINER_ARCH" ]; then
  CONTAINER_ARCH="amd64"
fi

HOST_ADDRESS="$(wget -q -O- http://ipinfo.io/ip/)"
if [ -z "$HOST_ADDRESS" ]; then
  echo "NOTICE: could not retrieve host's external IP address."
  echo -n "Please enter the host's external IP address: "; read -e HOST_ADDRESS
fi

echo -e "Creating container \"$CONTAINER_NAME\"..."

lxc-create -t download -n "$CONTAINER_NAME" -- -d ubuntu -r $CONTAINER_RELEASE -a $CONTAINER_ARCH
if [ "$?" != "0" ]; then
  echo "FATAL: error while creating container."; exit 1
fi

CONTAINER_DIR="/var/lib/lxc/$CONTAINER_NAME"
CONTAINER_ROOTFS="$CONTAINER_DIR/rootfs"
if [ ! -d "$CONTAINER_DIR" ]; then
  echo -e "FATAL: could not find container directory at \"$CONTAINER_DIR\"."; exit 1
fi

#echo -e "#!/bin/bash\n# This script runs on the host before starting the container" > $CONTAINER_DIR/pre-start.sh
#echo -e "# IPv6 routing: ip -6 neigh add proxy <container-ipv6> dev <host-iface>" >> $CONTAINER_DIR/pre-start.sh
#chmod a+x $CONTAINER_DIR/pre-start.sh
#echo -e "\nlxc.hook.pre-start = $CONTAINER_DIR/pre-start.sh" >> $CONTAINER_DIR/config
#echo -e "#!/bin/bash\n# This script runs on the host after stopping the container" > $CONTAINER_DIR/post-stop.sh
#echo -e "# IPv6 routing: ip -6 neigh del proxy <container-ipv6> dev <host-iface>" >> $CONTAINER_DIR/post-stop.sh
#chmod a+x $CONTAINER_DIR/post-stop.sh
#echo -e "lxc.hook.post-stop = $CONTAINER_DIR/post-stop.sh" >> $CONTAINER_DIR/config

if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  echo -n "Generating SSH keypair..."
  ssh-keygen -q -t rsa -N "" -f $HOME/.ssh/id_rsa
  echo " done!"
fi
mkdir -p $CONTAINER_ROOTFS/root/.ssh
chmod 700 $CONTAINER_ROOTFS/root/.ssh
cat $HOME/.ssh/id_rsa.pub > $CONTAINER_ROOTFS/root/.ssh/authorized_keys
chmod 600 $CONTAINER_ROOTFS/root/.ssh/authorized_keys
chown -R 100000:100000 $CONTAINER_ROOTFS/root/.ssh

echo "Setting up container connectivity..."

sed -i "s/127.0.1.1\s\{0,\}$CONTAINER_NAME/$HOST_ADDRESS $CONTAINER_NAME.s.laxis.it $CONTAINER_NAME/" $CONTAINER_ROOTFS/etc/hosts
sed -i "s/iface eth0 inet dhcp/iface eth0 inet static\n\taddress $CONTAINER_ADDRESS\n\tnetmask 255.255.255.0\n\tgateway $CONTAINER_GATEWAY\n\tdns-nameservers 8.8.8.8 8.8.4.4\n\tdns-search s.laxis.it/" $CONTAINER_ROOTFS/etc/network/interfaces

lxc-start -q -n "$CONTAINER_NAME" -d
echo "Waiting 10 seconds for container to start..."
sleep 10

echo "Deleting user ubuntu (and his home)..."

lxc-attach -q -n $CONTAINER_NAME -- deluser ubuntu --remove-home 1>/dev/null
if [ "$?" != "0" ]; then
  echo "NOTICE: could not delete user ubuntu..."
fi

echo "Setting up timezone..."

lxc-attach -q -n $CONTAINER_NAME -- rm -f /etc/localtime
lxc-attach -q -n $CONTAINER_NAME -- ln -s /usr/share/zoneinfo/CET /etc/localtime

echo "Checking container connectivity..."

lxc-attach -q -n $CONTAINER_NAME -- ping -A -c 4 -W 1 8.8.8.8 1>/dev/null
if [ "$?" != "0" ]; then
  echo "FATAL: container does not seem to be able to access the Internet."; exit 1
fi

echo "Updating APT packages lists..."

lxc-attach -q -n $CONTAINER_NAME -- apt-get -qq update
if [ "$?" != "0" ]; then
  echo "FATAL: there was a problem updating APT packages lists."; exit 1
fi

echo "Installing useful packages..."

lxc-attach -q -n $CONTAINER_NAME -- apt-get -qq -y install openssh-server nano bash-completion software-properties-common 1>/dev/null
if [ "$?" != "0" ]; then
  echo "FATAL: errors while installing packages."; exit 1
fi

echo
echo -e "Done!\nYou can now access the container with: ssh root@$CONTAINER_ADDRESS"
#echo -e "If you need global IPv6 access in your container, look in $CONTAINER_DIR/pre-start.sh and post-stop.sh"
