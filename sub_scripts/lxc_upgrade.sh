#!/bin/bash

# Récupère le dossier du script
if [ "${0:0:1}" == "/" ]; then script_dir="$(dirname "$0")"; else script_dir="$(echo $PWD/$(dirname "$0" | cut -d '.' -f2) | sed 's@/$@@')"; fi

if test -e "$script_dir/../pcheck.lock"
then	# L'upgrade est annulé
	echo "Le fichier $script_dir/../pcheck.lock est présent. Package check est déjà utilisé. Exécution annulée..."
	exit 0
fi
touch "$script_dir/../pcheck.lock" # Met en place le lock de Package check

PLAGE_IP=$(cat "$script_dir/lxc_build.sh" | grep PLAGE_IP= | cut -d '"' -f2)
LXC_NAME=$(cat "$script_dir/lxc_build.sh" | grep LXC_NAME= | cut -d '=' -f2)
LXC_BRIDGE=$(cat "$script_dir/lxc_build.sh" | grep LXC_BRIDGE= | cut -d '=' -f2)
if [ -e "$script_dir/../config" ]; then
	main_iface=$(cat "$script_dir/../config" | grep iface= | cut -d '=' -f2)
else	# Si le fichier de config n'existe pas
	# Tente de définir l'interface réseau principale
	main_iface=$(sudo route | grep default | awk '{print $8;}')	# Prend l'interface réseau défini par default
	if [ -z $main_iface ]; then
		echo -e "\e[91mImpossible de déterminer le nom de l'interface réseau de l'hôte.\e[0m"
		exit 1
	fi
	# Enregistre le nom de l'interface réseau de l'hôte dans un fichier de config
	echo -e "# interface réseau principale de l'hôte\niface=$main_iface\n" > "$script_dir/../config"
fi

# Check user
if [ "$(whoami)" != "$(cat "$script_dir/setup_user")" ] && test -e "$script_dir/setup_user"; then
	echo -e "\e[91mCe script doit être exécuté avec l'utilisateur $(cat "$script_dir/setup_user") !\nL'utilisateur actuel est $(whoami)."
	echo -en "\e[0m"
	rm "$script_dir/../pcheck.lock" # Retire le lock
	exit 0
fi

echo "\e[1m> Active le bridge réseau\e[0m"
if ! sudo ifquery $LXC_BRIDGE --state > /dev/null
then
	sudo ifup $LXC_BRIDGE --interfaces=/etc/network/interfaces.d/$LXC_BRIDGE
fi

echo "\e[1m> Configure le parefeu\e[0m"
if ! sudo iptables -D FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT 2> /dev/null
then
	sudo iptables -A FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT
fi
if ! sudo iptables -C FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT 2> /dev/null
then
	sudo iptables -A FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT
fi
if ! sudo iptables -t nat -C POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE 2> /dev/null
then
	sudo iptables -t nat -A POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
fi

echo "\e[1m> Démarrage de la machine\e[0m"
if [ $(sudo lxc-info --name $LXC_NAME | grep -c "STOPPED") -eq 0 ]; then
	# Si la machine n'est pas à l'arrêt.
	sudo lxc-stop -n $LXC_NAME	# Arrête la machine LXC
fi
# Restaure le snapshot
sudo rsync -aEAX --delete -i /var/lib/lxcsnaps/$LXC_NAME/snap0/rootfs/ /var/lib/lxc/$LXC_NAME/rootfs/ > /dev/null	# Pour être sûr!

sudo lxc-start -n $LXC_NAME -d
sleep 3
sudo lxc-ls -f

echo "\e[1m> Update\e[0m"
update_apt=0
sudo lxc-attach -n $LXC_NAME -- apt-get update
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade --dry-run | grep -q "^Inst "	# Vérifie si il y aura des mises à jour.
if [ "$?" -eq 0 ]; then
	update_apt=1
fi
echo "\e[1m> Upgrade\e[0m"
sudo lxc-attach -n $LXC_NAME -- apt-get dist-upgrade -y
echo "\e[1m> Clean\e[0m"
sudo lxc-attach -n $LXC_NAME -- apt-get autoremove -y
sudo lxc-attach -n $LXC_NAME -- apt-get autoclean
if [ "$update_apt" -eq 1 ]
then	# Print les numéros de version de Yunohost, si il y a eu un upgrade
	(sudo lxc-attach -n $LXC_NAME -- yunohost -v) | sudo tee "$script_dir/ynh_version"
fi

echo "\e[1m> Arrêt de la machine virtualisée\e[0m"
sudo lxc-stop -n $LXC_NAME

echo "\e[1m> Suppression des règles de parefeu\e[0m"
sudo iptables -D FORWARD -i $LXC_BRIDGE -o $main_iface -j ACCEPT
sudo iptables -D FORWARD -i $main_iface -o $LXC_BRIDGE -j ACCEPT
sudo iptables -t nat -D POSTROUTING -s $PLAGE_IP.0/24 -j MASQUERADE
sudo ifdown --force $LXC_BRIDGE


if [ "$update_apt" -eq 1 ]
then
	echo "\e[1m> Archivage du snapshot\e[0m"
	sudo tar -cz --acls --xattrs -f /var/lib/lxcsnaps/$LXC_NAME/snap0.tar.gz /var/lib/lxcsnaps/$LXC_NAME/snap0
	echo "\e[1m> Remplacement du snapshot\e[0m"
	sudo lxc-snapshot -n $LXC_NAME -d snap0
	sudo lxc-snapshot -n $LXC_NAME
fi

sudo rm "$script_dir/../pcheck.lock" # Retire le lock
