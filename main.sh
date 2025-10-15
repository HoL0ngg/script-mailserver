#!/bin/bash
#Các packages cần cài đắt
readonly PACKAGES=("bind" "bind-utils" "dovecot" "postfix" "epel-release" "squirrelmail")
readonly EXTERNAL_LINK_EPEL_RELEASE="https://dl.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm"

check_network_connection() {
	ping -c 1 8.8.8.8 &> /dev/null
}

#Kiểm tra trạng thái cài đặt package
is_installed() {
	local pkg=$1
	rpm -q "$pkg" &> /dev/null
	return $?
}

#Kiểm tra trạng thái cài đặt tất cả packages
check_packages_installed() {
	echo "======== Trạng thái cài đặt của các gói tin ========"
	local MISSING_PACKAGES=();
	for pkg in "${PACKAGES[@]}"; do
		if is_installed "$pkg"; then
			echo "[installed] $pkg đã được cài đặt"
		else
			MISSING_PACKAGES+=("$pkg")
		fi
	done
	
	for pkg in "${MISSING_PACKAGES[@]}"; do
		echo "[not installed] $pkg chưa được cài đặt"
	done
	echo "===================================================="
}

#Cài đặt package
install_package() {
	local pkg=$1
	local status=0
	if ! is_installed "$pkg"; then
		echo "[Installing] Đang cài đặt $pkg..."
		yum -y install "$pkg" &> /dev/null
		status=$?
		#Nếu không cài được epel-release thì phải cài qua URL trực tiếp
		if [[ $status -ne 0 && "$pkg" == "epel-release" ]]; then
			yum -y install "$EXTERNAL_LINK_EPEL_RELEASE" &> /dev/null
			status=$?
		fi
	fi
	if [ $status -ne 0 ]; then
		echo "[Error] Lỗi khi cài đặt $pkg."
		return 1
	fi
	return 0;
}

#Cài đặt tất cả packages
install_all_packages() {
	echo "============ Quá trình cài đặt các gói tin ============"
	if ! check_network_connection; then
		echo "[Error] Lỗi kết nối mạng."
		echo "[Info] Vui lòng kiểm tra kết nối mạng để tiến hành cài đặt."
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
			echo "[Error] $pkg có lỗi khi cài đặt."
		done
	else
		echo "[Success] Các gói tin đã được cài đặt thành công!"
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
				read -p "Nhấn Enter để quay lại menu..."
				;;
			
			2)
				install_all_packages
				read -p "Nhấn Enter để quay lại menu..."
				;;
			0)
				break;
				;;
			
			*)
				echo "[Error] Vui lòng chọn 0-2."
				read -p "Nhấn Enter để quay lại menu..."
				;;
		esac
	done	
}

#Menu chinh
menu_main() {
	#Kiem tra nguoi dung root
	if [ "$(id -u)" -ne 0 ]; then
		echo "Bạn cần chạy chương trình dưới quyền root (sudo)!"
		exit 1
	fi

	while true; do
		clear
		echo "================ MENU ================"
		echo "1) Cài đặt."
		echo "0) Thoát."
		echo "======================================"
		echo -n "Nhập lựa chọn [0-1]: "
		read choice
		clear
		case "$choice" in
			1)		
				menu_install
				;;
			
			0)
				echo "Đã thoát chương trình!"
				exit 0
				;;
			
			*)
				echo "[Error] Vui lòng chọn 0-1."
				read -p "Nhấn Enter để quay lại menu..."
				;;
		esac
	done
}

#Chương trình chính
menu_main