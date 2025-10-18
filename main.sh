#!/bin/bash
#Các packages cần cài đặt
readonly PACKAGES=("bind" "bind-utils" "dovecot" "postfix" "epel-release" "squirrelmail")
readonly EXTERNAL_LINK_EPEL_RELEASE="https://dl.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm"

pause() {
	read -p "Nhấn Enter để quay lại menu..."
}
check_network_connection() {
	ping -c 1 8.8.8.8 &> /dev/null
}

#Kiểm tra trạng thái cài đặt package
is_installed() {
	local pkg=$1
	rpm -q "$pkg" &> /dev/null
	return $?
}

is_all_installed() {
	for pkg in "${PACKAGES[@]}"; do
		if ! is_installed "$pkg"; then
			return 1
		fi
	done
	return 0
}

#Kiểm tra trạng thái cài đặt tất cả packages
check_packages_installed() {
	echo "======== Trạng thái cài đặt của các gói tin ========"
	local MISSING_PACKAGES=();
	for pkg in "${PACKAGES[@]}"; do
		if is_installed "$pkg"; then
			echo "[INSTALLED] $pkg đã được cài đặt"
		else
			MISSING_PACKAGES+=("$pkg")
		fi
	done
	
	for pkg in "${MISSING_PACKAGES[@]}"; do
		echo "[NOT INSTALLED] $pkg chưa được cài đặt"
	done
	echo "===================================================="
}

#Cài đặt package
install_package() {
	local pkg=$1
	local status=0
	if ! is_installed "$pkg"; then
		echo "[INSTALLING] Đang cài đặt $pkg..."
		yum -y install "$pkg" &> /dev/null
		status=$?
		#Nếu không cài được epel-release thì phải cài qua URL trực tiếp
		if [[ $status -ne 0 && "$pkg" == "epel-release" ]]; then
			yum -y install "$EXTERNAL_LINK_EPEL_RELEASE" &> /dev/null
			status=$?
		fi
	fi
	if [ $status -ne 0 ]; then
		echo "[ERROR] Lỗi khi cài đặt $pkg."
		return 1
	fi
	return 0;
}

#Cài đặt tất cả packages
install_all_packages() {
	echo "============ Quá trình cài đặt các gói tin ============"
	if ! check_network_connection; then
		echo "[ERROR] Lỗi kết nối mạng."
		echo "[INFO] Vui lòng kiểm tra kết nối mạng để tiến hành cài đặt."
		echo "======================================================="
		return 1
	fi
	local ERROR_PACKAGES=()
	for pkg in "${PACKAGES[@]}"; do
		if ! install_package "$pkg"; then
			ERROR_PACKAGES+=("$pkg")
		fi
	done
	if [ "${#ERROR_PACKAGES[@]}" -ne 0 ]; then
		echo "=== Tổng kết lỗi khi cài đặt ==="
		for pkg in "${ERROR_PACKAGES[@]}"; do
			echo "[ERROR] $pkg có lỗi khi cài đặt."
		done
	else
		echo "[SUCCESS] Các gói tin đã được cài đặt thành công!"
	fi
	echo "======================================================="
}

#Menu cho chuc nang 1 - Cai Dat
menu_install() {
	while true; do
		clear
		echo "============ MENU_CÀI_ĐẶT ============"
		echo "1) Kiểm tra các gói tin."
		echo "2) Cài đặt các gói tin."
		echo "0) Thoát cài đặt."
		echo "======================================"
		echo -n "Nhập lựa chọn [0-2]: "
		read choice
		clear
		case "$choice" in
			1)		
				check_packages_installed
				pause
				;;
			
			2)
				install_all_packages
				pause
				;;
			0)
				break;
				;;
			
			*)
				echo "[ERROR] Vui lòng chọn 0-2."
				pause
				;;
		esac
	done	
}

append_config() {
	local _file=$1
	local key=$2
	local value=$3
	local pattern="^${key}"

	readonly _file key value pattern
	if ! grep -Fxq "${key} = ${value}" "${_file}"; then
		sed -i -E "/${pattern}/ s|^|#|" "${_file}"
		echo "${key} = ${value}" >> "${_file}"
	fi
}

backup_file() {
	local _FILE=$1
	local BACKUP_FILE="${_FILE}.bak"
	if [ ! -f "${BACKUP_FILE}" ]; then
		cp "${_FILE}" "${BACKUP_FILE}"
	fi
}

config_postfix() {
	local POSTFIX_FILE="/etc/postfix/main.cf"
	readonly POSTFIX_FILE
	backup_file "${POSTFIX_FILE}"

	echo "[CONFIGURING] Đang cấu hình postfix"
	append_config "${POSTFIX_FILE}" "myhostname" "server.sgu.edu.vn"
	append_config "${POSTFIX_FILE}" "mydomain" "sgu.edu.vn"
	append_config "${POSTFIX_FILE}" "myorigin" "\$mydomain"
	append_config "${POSTFIX_FILE}" "inet_interfaces" "all"
	append_config "${POSTFIX_FILE}" "inet_protocols" "all"
	append_config "${POSTFIX_FILE}" "mydestination" "\$myhostname, localhost.\$mydomain, localhost, \$mydomain"
	append_config "${POSTFIX_FILE}" "mynetworks" "192.168.1.0/24, 127.0.0.0/8"
	append_config "${POSTFIX_FILE}" "home_mailbox" "Maildir/"

	systemctl enable postfix &> /dev/null
	systemctl start postfix &> /dev/null
}

config_dovecot() {
	local DOVECOT_FILE="/etc/dovecot/dovecot.conf"
	local MAIL_FILE="/etc/dovecot/conf.d/10-mail.conf"
	local AUTH_FILE="/etc/dovecot/conf.d/10-auth.conf"
	local MASTER_FILE="/etc/dovecot/conf.d/10-master.conf"
	
	backup_file "${DOVECOT_FILE}"
	backup_file "${MAIL_FILE}"
	backup_file "${AUTH_FILE}"
	backup_file "${MASTER_FILE}"

	readonly DOVECOT_FILE MAIL_FILE AUTH_FILE MASTER_FILE
	local WS="[[:space:]]"

	echo "[CONFIGURING] Đang cấu hình dovecot"
	append_config "${DOVECOT_FILE}" "protocols" "imap pop3 lmtp"
	append_config "${MAIL_FILE}" "mail_location" "maildir:~/Maildir"
	append_config "${AUTH_FILE}" "disable_plaintext_auth" "yes"
	append_config "${AUTH_FILE}" "auth_mechanisms" "plain login"

	local START_BLOCK="/^service dict {/"
	local END_BLOCK="/^}/"
	readonly START_BLOCK END_BLOCK

	sed -i "${START_BLOCK},${END_BLOCK} s|user.*|user = postfix|" "${MASTER_FILE}"
	sed -i "${START_BLOCK},${END_BLOCK} s|#${WS}*user.*|user = postfix|" "${MASTER_FILE}"
	sed -i "${START_BLOCK},${END_BLOCK} s|group.*|group = postfix|" "${MASTER_FILE}"
	sed -i "${START_BLOCK},${END_BLOCK} s|#${WS}*group.*|group = postfix|" "${MASTER_FILE}"

	systemctl enable dovecot &> /dev/null
	systemctl start dovecot &> /dev/null
}

config_httpd() {
	local HTTPD_FILE="/etc/httpd/conf/httpd.conf"
	readonly HTTPD_FILE
	backup_file "${HTTPD_FILE}"

	echo "[CONFIGURING] Đang cấu hình httpd"
	if ! grep -Fxq "Alias /webmail /usr/share/squirrelmail" "${HTTPD_FILE}"; then
		echo "Alias /webmail /usr/share/squirrelmail"	>>	"${HTTPD_FILE}"
		echo "<Directory /usr/share/squirrelmail>"		>>	"${HTTPD_FILE}"
		echo 	"Options Indexes FollowSymLinks"		>>	"${HTTPD_FILE}"
		echo 	"RewriteEngine On"						>>	"${HTTPD_FILE}"
		echo 	"AllowOverride All"						>>	"${HTTPD_FILE}"
		echo 	"DirectoryIndex index.php"				>>	"${HTTPD_FILE}"
		echo 	"Order allow,deny"						>>	"${HTTPD_FILE}"
		echo 	"Allow from all"						>>	"${HTTPD_FILE}"
		echo "</Directory>"								>>	"${HTTPD_FILE}"
	fi
}
restart_services() {
	echo "[CONFIGURING] Đang khởi động lại các dịch vụ"
	systemctl start firewalld &> /dev/null
	firewall-cmd --permanent --add-port=80/tcp &> /dev/null
	firewall-cmd --reload &> /dev/null
	systemctl restart postfix &> /dev/null
	systemctl restart dovecot &> /dev/null
	systemctl restart httpd &> /dev/null
}

config_mailserver() {
	echo "=========== Quá trình cấu hình Mail Server ==========="
	if ! is_all_installed; then
		echo "[ERROR] Một số gói tin cần thiết chưa được cài đặt!"
		echo "[INFO] Vui lòng sử dụng chức năng \"1. Cài đặt\"."
		echo "====================================================="
		return 1
	fi
	config_postfix
	config_dovecot
	config_httpd
	restart_services
	echo "[SUCCESS] Đã hoàn tất cấu hình Mail Server"
	echo "====================================================="
}

#Menu chinh
menu_main() {
	#Kiểm tra người dùng root
	if [ "$(id -u)" -ne 0 ]; then
		echo "Bạn cần chạy chương trình dưới quyền root (sudo)!"
		exit 1
	fi

	while true; do
		clear
		echo "================ MENU ================"
		echo "1) Cài đặt."
		echo "2) Cấu hình Mail Server."
		echo "0) Thoát."
		echo "======================================"
		echo -n "Nhập lựa chọn [0-2]: "
		read choice
		clear
		case "$choice" in
			1)		
				menu_install
				;;
			2)
				config_mailserver
				pause
				;;
			
			0)
				echo "Đã thoát chương trình!"
				exit 0
				;;
			
			*)
				echo "[ERROR] Vui lòng chọn 0-2."
				pause
				;;
		esac
	done
}

#Chương trình chính
menu_main