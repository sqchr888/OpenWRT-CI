#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

#移除luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} +
#修改默认主题
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} +
#修改immortalwrt.lan关联IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} +
#添加编译日期标识
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} +

#修改默认WIFI账号密码
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
ROUTER_TOOL="./package/emortal/luci-app-router-tool/root/etc/config/router-tool"
for file in "$ROUTER_TOOL" "$WIFI_UC"; do
	[ -f "$file" ] && sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$file"
done

#将 WRT_SSID 真正作用到 mac80211.uc 默认 WiFi 名兜底（否则真机仍显示 OWRT）
WIFI_UC_MAC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
[ -f "$WIFI_UC_MAC" ] && sed -i "s/|| 'OWRT'/|| '$WRT_SSID'/g" "$WIFI_UC_MAC"

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#引入私有扩展配置
if [ -f "$GITHUB_WORKSPACE/Config/PRIVATE.txt" ]; then
	echo "Applying private configurations from PRIVATE.txt..."
	cat $GITHUB_WORKSPACE/Config/PRIVATE.txt >> ./.config
fi

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/dts/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#无WIFI配置调整Q6大小
	if [[ "$WRT_WIFI" == "WIFI-NO" ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
fi

#BE10000 端口调整（qualcommbe/ipq95xx）：10G 口改名 10G，默认 WAN 改到 lan1
if [[ "${WRT_TARGET^^}" == *"QUALCOMMBE"* ]]; then
	#把 10G RJ45 口（设备树 label="wan"）改名为 "10G"，避免与 WAN 角色混淆
	#注意：MAC 基址用的是节点名 &ppe_port5（label-mac-device），与 label 无关，改名不影响 MAC
	DTS_FILE="./target/linux/qualcommbe/dts/ipq9570-be10000.dts"
	if [ -f "$DTS_FILE" ]; then
		sed -i 's/label = "wan"/label = "10G"/' "$DTS_FILE"
		echo "be10000: 10G 口已改名 10G"
	fi
	#默认 WAN 从 10G 口(lan_wan)改绑到 lan1；10G 口归入 LAN 桥
	#原默认：ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4 sfp" "wan"
	NET_SCRIPT=$(grep -rl "ipq95xx_setup_interfaces" ./target/linux/qualcommbe/ 2>/dev/null | head -1)
	if [ -n "$NET_SCRIPT" ]; then
		sed -i 's/ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4 sfp" "wan"/ucidef_set_interfaces_lan_wan "lan2 lan3 lan4 sfp 10G" "lan1"/' "$NET_SCRIPT"
		echo "be10000: 默认 WAN 已改到 lan1，10G 归入 LAN"
	fi

	#BE10000 自定义：首次启动默认项（写入 base-files overlay，烤进镜像，仅首次启动执行一次）
	UCI_DEF_DIR="./package/base-files/files/etc/uci-defaults"
	mkdir -p "$UCI_DEF_DIR"

	#① 默认 Web 管理界面语言设为简体中文（源码自带 zh_Hans 语言包，已随 CONFIG_LUCI_LANG_zh_Hans=y 编入）
	cat > "$UCI_DEF_DIR/99-default-lang" <<'EOF'
#!/bin/sh
# BE10000：默认 Web 管理界面语言设为简体中文(zh_Hans)
if [ -x /usr/bin/uci ]; then
	uci -q set luci.main.lang='zh_Hans'
	uci -q commit luci
fi
exit 0
EOF
	chmod +x "$UCI_DEF_DIR/99-default-lang"
	echo "be10000: 已写入默认语言 uci-defaults (zh_Hans)"

	#② 默认 WAN 网络模式设为 PPPoE（端口已在上面改到 lan1；用户名/密码留空，首次启动后请在 LuCI 填写）
	cat > "$UCI_DEF_DIR/99-wan-pppoe" <<'EOF'
#!/bin/sh
# BE10000：默认 WAN 网络模式设为 PPPoE（拨号账号/密码首次启动后于 LuCI 填写）
if [ -x /usr/bin/uci ] && uci -q get network.wan >/dev/null 2>&1; then
	uci -q set network.wan.proto='pppoe'
	uci -q commit network
fi
exit 0
EOF
	chmod +x "$UCI_DEF_DIR/99-wan-pppoe"
	echo "be10000: 已写入默认 WAN 模式 uci-defaults (pppoe)"
fi
