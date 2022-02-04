#!/bin/sh

if [[ $EUID -ne 0 ]]; then
    clear
    echo "Error: This Script Must Be Run as Root!" 1>&2
    exit 1
fi

function CopyRight() {
  clear
  echo "#################################################################"
  echo "#                                                               #"
  echo "#  Auto Reinstall OS For VPS With SSH Script                    #"
  echo "#                                                               #"
  echo "#################################################################"
  echo -e "\n"
}

function isValidIp() {
  local ip=$1
  local ret=1
  if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    ip=(${ip//\./ })
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    ret=$?
  fi
  return $ret
}

function ipCheck() {
  isLegal=0
  for add in $MAINIP $GATEWAYIP $NETMASK; do
    isValidIp $add
    if [ $? -eq 1 ]; then
      isLegal=1
    fi
  done
  return $isLegal
}

function GetIp() {
  MAINIP=$(ip route get 1 | awk -F 'src ' '{print $2}' | awk '{print $1}')
  GATEWAYIP=$(ip route | grep default | awk '{print $3}' | head -1)
  SUBNET=$(ip -o -f inet addr show | awk '/scope global/{sub(/[^.]+\//,"0/",$4);print $4}' | head -1 | awk -F '/' '{print $2}')
  value=$(( 0xffffffff ^ ((1 << (32 - $SUBNET)) - 1) ))
  NETMASK="$(( (value >> 24) & 0xff )).$(( (value >> 16) & 0xff )).$(( (value >> 8) & 0xff )).$(( value & 0xff ))"
}

function UpdateIp() {
  read -r -p "Your IP: " MAINIP
  read -r -p "Your Gateway: " GATEWAYIP
  read -r -p "Your Netmask: " NETMASK
}

function SetNetwork() {
  isAuto='0'
  if [[ -f '/etc/network/interfaces' ]];then
    [[ ! -z "$(sed -n '/iface.*inet static/p' /etc/network/interfaces)" ]] && isAuto='1'
    [[ -d /etc/network/interfaces.d ]] && {
      cfgNum="$(find /etc/network/interfaces.d -name '*.cfg' |wc -l)" || cfgNum='0'
      [[ "$cfgNum" -ne '0' ]] && {
        for netConfig in `ls -1 /etc/network/interfaces.d/*.cfg`
        do
          [[ ! -z "$(cat $netConfig | sed -n '/iface.*inet static/p')" ]] && isAuto='1'
        done
      }
    }
  fi

  if [[ -d '/etc/sysconfig/network-scripts' ]];then
    cfgNum="$(find /etc/network/interfaces.d -name '*.cfg' |wc -l)" || cfgNum='0'
    [[ "$cfgNum" -ne '0' ]] && {
      for netConfig in `ls -1 /etc/sysconfig/network-scripts/ifcfg-* | grep -v 'lo$' | grep -v ':[0-9]\{1,\}'`
      do
        [[ ! -z "$(cat $netConfig | sed -n '/BOOTPROTO.*[sS][tT][aA][tT][iI][cC]/p')" ]] && isAuto='1'
      done
    }
  fi
}

function NetMode() {
  CopyRight

  if [ "$isAuto" == '0' ]; then
    read -r -p "Using DHCP to configure network automatically? [Y/n]:" input
    case $input in
      [yY][eE][sS]|[yY]) NETSTR='' ;;
      [nN][oO]|[nN]) isAuto='1' ;;
      *) NETSTR='' ;;
    esac
  fi

  if [ "$isAuto" == '1' ]; then
    GetIp
    ipCheck
    if [ $? -ne 0 ]; then
      echo -e "Error occurred when detecting ip. Please input manually.\n"
      UpdateIp
    else
      CopyRight
      echo "IP: $MAINIP"
      echo "Gateway: $GATEWAYIP"
      echo "Netmask: $NETMASK"
      echo -e "\n"
      read -r -p "Confirm? [Y/n]:" input
      case $input in
        [yY][eE][sS]|[yY]) ;;
        [nN][oO]|[nN])
          echo -e "\n"
          UpdateIp
          ipCheck
          [[ $? -ne 0 ]] && {
            clear
            echo -e "Input error!\n"
            exit 1
          }
        ;;
        *) ;;
      esac
    fi
    NETSTR="--ip-addr ${MAINIP} --ip-gate ${GATEWAYIP} --ip-mask ${NETMASK}"
  fi
}

function BootConf() {
  touch /tmp/bootconf.sh
  echo '#!/bin/sh'>/tmp/bootconf.sh

  staticIp='1'
  if [ "$isAuto" == '1' ]; then
    echo -e "\n"
    read -r -p "Using static ip? [Y/n]: " input
    case $input in
      [yY][eE][sS]|[yY]) staticIp='0' ;;
      *) staticIp='1' ;;
    esac
  fi

  if [ "$isAuto" == '1' ] && [ "$staticIp" == '0' ]; then
    cat >>/tmp/bootconf.sh <<EOF
sed -i 's/dhcp/static/' /etc/sysconfig/network-scripts/ifcfg-eth0;
echo -e "IPADDR=$MAINIP\nNETMASK=$NETMASK\nGATEWAY=$GATEWAYIP\nDNS1=8.8.8.8\nDNS2=8.8.4.4" >> /etc/sysconfig/network-scripts/ifcfg-eth0
EOF
  fi
  cat >>/tmp/bootconf.sh <<EOF
rm -f /etc/rc.d/rc.local
cp -f /etc/rc.d/rc.local.bak /etc/rc.d/rc.local
rm -rf /bootconf.sh
shutdown -r now
EOF
  sed -i '/sbin\/reboot/i\ sync; umount \\$(list-devices partition |head -n1); mount -t ext4 \\$(list-devices partition |head -n1) \/mnt; cp -f \/mnt\/etc\/rc.d\/rc.local \/mnt\/etc\/rc.d\/rc.local.bak; chmod +x \/mnt\/etc\/rc.d\/rc.local; cp -f \/bootconf.sh \/mnt\/bootconf.sh; chmod 755 \/mnt\/bootconf.sh; echo \"\/bootconf.sh\" >> \/mnt\/etc\/rc.d\/rc.local; sync; umount \/mnt; \\' /tmp/InstallNET.sh
  sed -i '/newc/i\cp -f \/tmp\/bootconf.sh \/tmp\/boot\/bootconf.sh'  /tmp/InstallNET.sh
}

function Start() {
  wget -qO /tmp/InstallNET.sh 'https://raw.githubusercontent.com/Lvellios/Reinstall-OS/main/InstallNET.sh' && chmod a+x /tmp/InstallNET.sh

  sed -i 's/$1$4BJZaD0A$y1QykUnJ6mXprENfwpseH0/$1$7R4IuxQb$J8gcq7u9K0fNSsDNFEfr90/' /tmp/InstallNET.sh

  echo -e "\nPlease Select An OS:"
  echo "  1) CentOS 7 X64"
  echo "  2) CentOS 8 X64"
  echo "  4) Debian 9 X64"
  echo "  5) Debian 10 X64"
  echo "  6) Debian 11 X64"
  echo "  7) Ubuntu 16.04 X64"
  echo "  8) Ubuntu 18.04 X64"
  echo "  9) Ubuntu 20.04 X64"
  echo "  10) Custom image"
  echo "  0) Exit"
  echo -ne "\nYour option: "
  read N
  case $N in
    1) echo -e "\Password: W0JNYLTMIRE7\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/
    InstallNET.sh -c 7 -v 64 -a $NETSTR $CMIRROR ;;

    2) echo -e "\Password: Pwd@CentOS\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/
    InstallNET.sh -c 8 -v 64 -a $NETSTR $CMIRROR ;;

    3) echo -e "\Password: W0JNYLTMIRE7\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/InstallNET.sh -d 9 -v 64 -a $NETSTR $DMIRROR ;;

    4) echo -e "\Password: W0JNYLTMIRE7\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/InstallNET.sh -d 10 -v 64 -a $NETSTR $DMIRROR ;;

    5) echo -e "\Password: W0JNYLTMIRE7\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/InstallNET.sh -d 11 -v 64 -a $NETSTR $DMIRROR ;;

    6) echo -e "\Password: W0JNYLTMIRE7\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/InstallNET.sh -u 16.04 -v 64 -a $NETSTR $UMIRROR ;;

    7) echo -e "\Password: W0JNYLTMIRE7\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/InstallNET.sh -u 18.04 -v 64 -a $NETSTR $UMIRROR ;;

    8) echo -e "\Password: W0JNYLTMIRE7\n"; read -s -n1 -p "Press any key to continue..." ; bash /tmp/InstallNET.sh -u 20.04 -v 64 -a $NETSTR $UMIRROR ;;

    9)
      echo -e "\n"
      read -r -p "Custom image URL: " imgURL
      echo -e "\n"
      read -r -p "Are you sure start reinstall? [y/N]: " input
      case $input in
        [yY][eE][sS]|[yY]) bash /tmp/InstallNET.sh $NETSTR -dd $imgURL $DMIRROR ;;
        *) clear; echo "Canceled by user!"; exit 1;;
      esac
      ;;
    0) exit 0;;
    *) echo "Wrong input!"; exit 1;;
  esac
}

SetNetwork
NetMode
Start
