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

	#②续：构建期直接把 LuCI 默认语言烤进镜像的 shipped 默认配置
	# luci-base 把 `option lang 'auto'` 写进 root/etc/config/luci 随镜像发布，且它本身
	# 不带任何 uci-defaults 脚本；只靠 firstboot 的 99-default-lang 会在「保留配置升级」
	# 时失效(旧的 /etc/config/luci 被保留)。这里在构建期改掉 shipped 默认值，保证全新
	# 刷写后默认界面语言就是简体中文，且不依赖 firstboot。
	LUCI_DEF_CONF="./feeds/luci/modules/luci-base/root/etc/config/luci"
	# 兜底：若 luci feed 目录名不是 feeds/luci（如 immortalwrt 自定义），自动定位
	[ -f "$LUCI_DEF_CONF" ] || LUCI_DEF_CONF=$(find ./feeds -path '*luci-base/root/etc/config/luci' 2>/dev/null | head -1)
	if [ -n "$LUCI_DEF_CONF" ] && [ -f "$LUCI_DEF_CONF" ]; then
		sed -i "s/option lang 'auto'/option lang 'zh_Hans'/" "$LUCI_DEF_CONF"
		echo "be10000: 已将 luci-base shipped 默认语言改为 zh_Hans(构建期烤入) -> $LUCI_DEF_CONF"
	else
		echo "be10000: 未找到 luci-base 默认配置，跳过语言烤入"
	fi

	#③ BE10000：修复 luci-app-xiaomi-control 风扇/RGB 取不到数据
	# 该 ACL 文件归 luci-app-xiaomi-control 包自身所有(构建时装包会释放此路径)，
	# 故不能用 package/base-files/files 覆盖(会被包的释放动作覆盖回残缺版)。
	# 正确做法：构建期直接覆盖包自带的 ACL 源文件，让包带着修好的 ACL 编进镜像
	#(全新刷写/升级均生效，无需首启 uci-defaults)。固定版源文件见 Config/xiaomi-control-acl/。
	XM_ACL_SRC="${GITHUB_WORKSPACE:-.}/Config/xiaomi-control-acl/luci-app-xiaomi-control.json"
	# 修复：包实际装在 package/<feed>/ 下(find ./feeds 搜不到)，且需精确锁定 rpcd/acl.d 那个 ACL
	XM_ACL_DST=$(find ./feeds ./package -path '*rpcd/acl.d/luci-app-xiaomi-control.json' 2>/dev/null | head -1)
	if [ -n "$XM_ACL_DST" ] && [ -f "$XM_ACL_SRC" ]; then
		cp -f "$XM_ACL_SRC" "$XM_ACL_DST"
		chmod 644 "$XM_ACL_DST"
		echo "be10000: 已将 luci-app-xiaomi-control ACL 覆盖为修复版 -> $XM_ACL_DST"
	else
		echo "be10000: 未找到 luci-app-xiaomi-control 的 ACL 源/目标，跳过 ACL 修复(源=$XM_ACL_SRC 目标=$XM_ACL_DST)"
	fi
fi
