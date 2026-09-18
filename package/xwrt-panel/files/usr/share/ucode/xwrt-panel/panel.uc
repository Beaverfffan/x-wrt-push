'use strict';
/*
 * xwrt-panel — minimal statistics panel for the GL-BE10000 / BE14000 TFT.
 *
 * X-Wrt style: swipeable pages, no lock screen, no PIN, no weather. Written
 * from scratch on ucode-mod-lvgl, using only the public lv/ubus/uci/uloop
 * bindings.
 *
 * Pages: usage (WAN rates), system (CPU / memory / thermal / fan), clients
 * (leases plus per-client rate from natflow), ports (per-port link and
 * rate), wan (every WAN interface) and wifi.
 *
 * The panel paints the x-wrt mark on the glass while it starts up.
 *
 * Per-client rate comes from /dev/natflow_userinfo_ctl, which x-wrt's
 * natflow already maintains; nothing extra has to be installed.
 */

import * as lv from 'lv';
import * as ubus from 'ubus';
import * as uci from 'uci';
import * as uloop from 'uloop';
import { readfile, writefile, lsdir } from 'fs';

/* ------------------------------------------------------------------ */
/* 常量区 —— 所有顶层 const。
 * ucode 在“声明点”绑定顶层名字：函数里用到【定义在它之后】的名字会在运行时
 * 直接报 `access to undeclared variable`（当值用）或 `left-hand side is not
 * a function`（当函数调），与调用顺序无关。所以值声明一律集中在最前面，
 * 函数区再按「被调用者在前」排序 —— 两件事都别破坏。
 *
 * 改完务必跑：python3 _tools/ucode_scope_check.py panel.uc   （rc=0 才交）
 */
/* ------------------------------------------------------------------ */
const W = 320;
const H = 240;
const POINTS = 28;

/*
 * Page geometry. These sit up here on purpose: ucode binds a top level
 * const at the point of its declaration, so a function defined above one
 * cannot see it at run time and dies with "access to undeclared
 * variable". card_new() is defined well before the page builders, so
 * BODY_Y and BODY_H have to be declared first.
 */
const HEAD_TOP = 11;
const HEAD_X = 12;
const BODY_Y = 44;
const BODY_H = H - BODY_Y - 12;

/*
 * 统一版式。六个页面共用这一套数字 —— 以前每页各写一份，行高、右侧数值列的
 * x/宽度、副行偏移都略有差别，看起来就不是一套东西。
 */
const CARD_X = 10;
const CARD_W = W - 20;
const CARD_R = 12;
const ROW_X = 16;			/* 卡片内左边界 */
const RIGHT_EDGE = CARD_W - ROW_X;	/* 卡片内右边界 */
const RIGHT_W = 90;			/* 右侧数值列宽 */
const RIGHT_X = RIGHT_EDGE - RIGHT_W;
const ROW_W = RIGHT_EDGE - ROW_X;	/* 内容宽度 */
const ROW_TOP = 8;			/* 列表页首行 y */
const ROW_H = 40;			/* 列表页行高 */
const ROW_SUB = 17;			/* 副行相对主行的偏移 */
const DOT_X = ROW_X;
const DOT_OFF = 3;
const DOT_S = 7;
const TEXT_DOT_X = ROW_X + 15;		/* 有状态点时的文字 x */
const RULE_GAP = 3;
const GRID_TOP = 12;			/* 静态页「标签 — 数值」行起点 */
const GRID_STEP = 26;
const MID = 140;			/* 静态页左列右边界 */
const CHART_Y = GRID_TOP + 78;
const CHART_H = BODY_H - CHART_Y - 10;
const C_SCREEN = 0x000000;
const C_SURFACE = 0x1c1c1e;
const C_RULE = 0x636366;
const C_TXT = 0xffffff;
const C_DIM = 0x9a9aa2;
const C_IDLE = 0x3e3e44;
const C_RX = 0x0a6cff;
const C_TX = 0x64d2ff;
const C_OK = 0x32d74b;
const C_DOWN = 0xff453a;
const FONT_DIR = '/usr/share/xwrt-panel/fonts';
const LOGO_FILE = '/usr/share/xwrt-panel/xwrt-logo.png';
const NATFLOW_USERINFO = '/dev/natflow_userinfo_ctl';
const state = {
	hostname: 'openwrt',
	clock: '',
	wan_device: null,
	wan_rx: null, wan_tx: null, wan_ts: null,
	rx_total: 0, tx_total: 0,
	rx: [], tx: [],
	rx_rate: 0, tx_rate: 0,
	cpu: null, cpu_prev_total: null, cpu_prev_idle: null,
	load: null,
	mem_total: 0, mem_avail: 0,
	temp: null, fan: null,
	uptime: 0,
	ports: [],
	clients: [],
	wan_ifaces: [],
	networks: []
};

const PORT_RE = /^(wan|lan[0-9]+|sfp)$/;

/* ------------------------------------------------------------------ */
/* 模块状态 —— 所有可变的顶层 let。同样必须在任何函数之前。 */
/* ------------------------------------------------------------------ */
let cfg = {
	brightness: 80,
	rotate: 0,	/* seconds, 0 = off */
	blank: 5,	/* minutes idle before backlight off, 0 = never */
	splash: 3,	/* seconds the x-wrt mark stays up, 0 = no splash */
	wan_ifaces: null,	/* explicit list, null = auto detect */
	page_usage: true,
	page_system: true,
	page_clients: true,
	page_ports: true,
	page_wifi: true
};

let bl_path, bl_max = 100;
let F_TITLE, F_BIG, F_MED, F_SMALL;
let pages = [];		/* { name, tile, update?, poll? } */
let dots = [];
let active = 0;
let screen, tileview;
let clock_label;	/* text_new() wrapper */
let last_touch;
let usage = {};
let sys_pg = {};
let clients_pg = {};
let ports_pg = {};
let wifi_pg = {};

/* Same reason as the geometry constants above: touch_note() reads it. */
let blanked = false;

/* splash — the x-wrt mark while the panel starts up                   */
let splash_obj = null;
let splash_deadline = 0;
let touch_device = getenv('PANEL_TOUCH_DEVICE');
let rotate_tick = 0;

/* ------------------------------------------------------------------ */
/* 函数区 —— 按「被调用者在前」拓扑排序，不是风格偏好。
 *
 * 顺序：
 *   truish config_read backlight_find backlight_set face fonts_load
 *   label_new box_new bar_new text_new text_set value_new
 *   text_w row_dot row_rule row_main row_sub row_value
 *   grid_row empty_new monotonic ubus_call num wan_device_read
 *   counter_read wan_read words sys_read port_speed ports_read
 *   natflow_split clients_merge_natflow clients_sort clients_read
 *   band_of security_of wifi_read clock_read rate_fmt rate_short
 *   row_rate total_fmt speed_fmt uptime_fmt header_new bar_scaled
 *   usage_update system_update clients_update ports_update wifi_update
 *   dots_refresh page_show touch_note card_new usage_build system_build
 *   clients_build ports_build wifi_build tile_changed blank_check
 *   dir_for frame_build splash_hide splash_check splash_show
 */
/* ------------------------------------------------------------------ */
function truish(v) {
	return index([ '1', 'on', 'true', 'yes', 'enabled' ], lc(v ?? '')) >= 0;
}

function config_read() {
	let cursor = uci.cursor();

	if (!cursor.load('xwrt_panel'))
		return;

	let g = (name) => cursor.get('xwrt_panel', '@panel[0]', name);

	if (+g('brightness') >= 10 && +g('brightness') <= 100)
		cfg.brightness = +g('brightness');
	if (+g('rotate') >= 0)
		cfg.rotate = +g('rotate');
	if (+g('blank') >= 0)
		cfg.blank = +g('blank');
	if (+g('splash') >= 0)
		cfg.splash = +g('splash');

	let list = g('wan_ifaces');

	if (list)
		cfg.wan_ifaces = filter(split(replace(trim(list), /[,\t ]+/g, ' '), ' '),
					p => p != '');

	for (let key in [ 'page_usage', 'page_system', 'page_clients', 'page_ports',
			  'page_wifi' ]) {
		if (g(key) != null)
			cfg[key] = truish(g(key));
	}
}

function backlight_find() {
	for (let d in lsdir('/sys/class/backlight') ?? []) {
		let max = readfile(sprintf('/sys/class/backlight/%s/max_brightness', d));

		if (max) {
			bl_path = sprintf('/sys/class/backlight/%s', d);
			bl_max = +trim(max) || 100;
			return;
		}
	}
}

function backlight_set(pct) {
	if (!bl_path)
		return;

	writefile(bl_path + '/brightness',
		  sprintf('%d', int(bl_max * pct / 100)));
}

/* fonts / widgets                                                     */
function face(name) {
	try {
		return lv.font_load(sprintf('%s/%s.bin', FONT_DIR, name));
	}
	catch (e) {
		return null;
	}
}

function fonts_load() {
	F_TITLE = face('inter_semibold_21') ?? face('inter_semibold_15');
	F_BIG = face('inter_light_45') ?? face('inter_regular_26') ?? F_TITLE;
	F_MED = face('inter_regular_15') ?? face('inter_regular_13');
	F_SMALL = face('inter_regular_13') ?? face('inter_regular_11') ?? F_MED;
}

function label_new(parent, font, colour, text) {
	let l = lv.label(parent);

	l.text(text);

	let st = { text_color: colour };

	if (font)
		st.text_font = font;

	l.style(st);

	return l;
}

function box_new(parent, colour, radius) {
	let b = lv.obj(parent);

	b.style({ bg_color: colour, radius, border_width: 0, pad_all: 0 });
	b.clickable(false);
	b.scrollable(false);

	return b;
}

function bar_new(parent, colour, radius) {
	let b = lv.bar(parent);

	b.style({ bg_color: C_IDLE, radius, border_width: 0, pad_all: 0 });
	b.style({ bg_color: colour, radius }, lv.PART_INDICATOR);
	b.range(0, 100);
	b.value(0);
	b.clickable(false);
	b.scrollable(false);

	return b;
}

/* label wrapper that only redraws on change */
function text_new(parent, font, colour, text) {
	return { obj: label_new(parent, font, colour, text), last: text };
}

function text_set(t, text) {
	if (t.last == text)
		return;

	t.last = text;
	t.obj.text(text);
}

/* right aligned label wrapper */
function value_new(parent, font, colour, text) {
	let t = text_new(parent, font, colour, text);

	t.obj.style({ text_align: lv.TEXT_ALIGN_RIGHT });

	return t;
}

/* text width with a usable fallback when a font failed to load */
function text_w(font, s) {
	return font ? lv.text_width(font, s) : 7 * length(s);
}

/*
 * 列表行的统一版式。四个列表页（clients / ports / wan / wifi）共用：
 *
 *   [dot]  主行文字                              右侧上行
 *          副行文字                              右侧下行
 *   ─────────────────────────────────────────────────────────
 *
 * 行高 ROW_H、副行偏移 ROW_SUB、右侧列 RIGHT_X / RIGHT_W 都取自上方的常量。
 */
function row_dot(card, y, up) {
	box_new(card, up ? C_OK : C_DOWN, 4)
		.set({ x: DOT_X, y: y + DOT_OFF, w: DOT_S, h: DOT_S });
}

function row_rule(card, y) {
	box_new(card, C_RULE, 0).set({ x: ROW_X, y: y - RULE_GAP, w: ROW_W, h: 1 });
}

function row_main(card, y, text, has_dot, width) {
	let x = has_dot ? TEXT_DOT_X : ROW_X;
	let t = label_new(card, F_SMALL, C_TXT, text);

	t.set({ x: x, y: y, w: width ?? (RIGHT_X - x - 8) });

	return t;
}

function row_sub(card, y, text, has_dot) {
	let x = has_dot ? TEXT_DOT_X : ROW_X;

	return label_new(card, F_SMALL, C_DIM, text)
		.set({ x: x, y: y + ROW_SUB, w: RIGHT_X - x - 8 });
}

function row_value(card, y, text, colour) {
	let v = value_new(card, F_SMALL, colour ?? C_TXT, text);

	v.obj.set({ x: RIGHT_X, y: y, w: RIGHT_W });

	return v;
}

/* 静态页的「左标签 — 右数值」行，i 从 0 起，行距 GRID_STEP */
function grid_row(card, i, name, colour) {
	let y = GRID_TOP + i * GRID_STEP;

	label_new(card, F_SMALL, C_DIM, name).set({ x: ROW_X, y: y + 3 });

	return row_value(card, y, '--', colour);
}

function empty_new(card, text) {
	label_new(card, F_SMALL, C_DIM, text).set({ x: ROW_X, y: ROW_TOP });
}

function monotonic() {
	let c = clock(true);

	return c[0] + c[1] / 1000000000.0;
}

function ubus_call(object, method, data) {
	try {
		return ubus.call({ object, method, data: data ?? {} });
	}
	catch (e) {
		return null;
	}
}

function num(v) {
	let n = +v;

	return (n == n) ? n : 0;	/* NaN guard */
}

function wan_device_read() {
	let wan = ubus_call('network.interface.wan', 'status');

	state.wan_device = wan?.l3_device ?? wan?.device;
}

function counter_read(dev, name) {
	let raw = readfile(sprintf('/sys/class/net/%s/statistics/%s', dev, name));

	return raw ? +trim(raw) : null;
}

function wan_read() {
	let now = monotonic();

	if (!state.wan_device)
		wan_device_read();

	let rx = state.wan_device ? counter_read(state.wan_device, 'rx_bytes') : null;
	let tx = state.wan_device ? counter_read(state.wan_device, 'tx_bytes') : null;

	if (rx == null || tx == null) {
		state.rx_rate = 0;
		state.tx_rate = 0;
	} else {
		let dt = state.wan_ts != null ? now - state.wan_ts : 0;

		if (dt > 0 && rx >= state.wan_rx && tx >= state.wan_tx) {
			state.rx_rate = int((rx - state.wan_rx) / dt);
			state.tx_rate = int((tx - state.wan_tx) / dt);
		}

		state.wan_rx = rx;
		state.wan_tx = tx;
		state.wan_ts = now;
		state.rx_total = rx;
		state.tx_total = tx;
	}

	push(state.rx, state.rx_rate);
	push(state.tx, state.tx_rate);

	while (length(state.rx) > POINTS)
		shift(state.rx);
	while (length(state.tx) > POINTS)
		shift(state.tx);
}

function words(line) {
	return filter(split(replace(trim(line), /[ \t]+/g, ' '), ' '),
		      p => p != '');
}

function sys_read() {
	/* CPU: busy share of the delta between two samples of /proc/stat */
	let stat = readfile('/proc/stat');

	if (stat) {
		let f = words(split(stat, '\n')[0]);
		let total = 0, idle = 0;

		for (let i = 1; i < length(f); i++) {
			let v = num(f[i]);

			total += v;
			if (i == 4 || i == 5)	/* idle, iowait */
				idle += v;
		}

		if (state.cpu_prev_total != null) {
			let dt = total - state.cpu_prev_total;
			let di = idle - state.cpu_prev_idle;

			if (dt > 0)
				state.cpu = int(100 * (dt - di) / dt);
		}

		state.cpu_prev_total = total;
		state.cpu_prev_idle = idle;
	}

	let load = readfile('/proc/loadavg');

	if (load) {
		let f = words(load);

		state.load = sprintf('%s %s %s', f[0], f[1], f[2]);
	}

	let mem = readfile('/proc/meminfo');

	if (mem) {
		for (let line in split(mem, '\n')) {
			let f = words(line);

			if (f[0] == 'MemTotal:')
				state.mem_total = num(f[1]) * 1024;
			else if (f[0] == 'MemAvailable:')
				state.mem_avail = num(f[1]) * 1024;
		}
	}

	/* thermal: the hottest zone wins */
	let temp = null;

	for (let d in lsdir('/sys/class/thermal') ?? []) {
		if (index(d, 'thermal_zone') != 0)
			continue;

		let raw = readfile(sprintf('/sys/class/thermal/%s/temp', d));
		let v = raw ? num(trim(raw)) : 0;

		if (v > 0 && (temp == null || v > temp))
			temp = v;
	}

	if (temp == null) {
		for (let d in lsdir('/sys/class/hwmon') ?? []) {
			let raw = readfile(sprintf('/sys/class/hwmon/%s/temp1_input', d));
			let v = raw ? num(trim(raw)) : 0;

			if (v > 0 && (temp == null || v > temp))
				temp = v;
		}
	}

	state.temp = temp != null ? int(temp / 1000) : null;

	/* fan: any hwmon that has a tachometer */
	let fan = null;

	for (let d in lsdir('/sys/class/hwmon') ?? []) {
		let raw = readfile(sprintf('/sys/class/hwmon/%s/fan1_input', d));

		if (raw) {
			fan = num(trim(raw));
			break;
		}
	}

	state.fan = fan;

	let up = readfile('/proc/uptime');

	if (up)
		state.uptime = int(num(trim(split(trim(up), ' ')[0])));
}

function port_speed(dev) {
	let raw = readfile(sprintf('/sys/class/net/%s/speed', dev));

	if (!raw)
		return null;

	let v = num(trim(raw));

	return v > 0 ? v : null;
}

function ports_read() {
	let now = monotonic();
	let found = [];

	for (let dev in lsdir('/sys/class/net') ?? []) {
		if (!match(dev, PORT_RE))
			continue;

		let carrier = readfile(sprintf('/sys/class/net/%s/carrier', dev));
		let up = carrier != null && num(trim(carrier)) == 1;

		let rx = counter_read(dev, 'rx_bytes');
		let tx = counter_read(dev, 'tx_bytes');

		let rec = {
			name: dev,
			up,
			speed: up ? port_speed(dev) : null,
			rx_rate: 0, tx_rate: 0
		};

		let prev = null;

		for (let p in state.ports)
			if (p.name == dev) {
				prev = p;
				break;
			}

		if (rx != null && tx != null) {
			rec.rx_total = rx;
			rec.tx_total = tx;
			rec.ts = now;

			if (prev && prev.ts != null && prev.rx_total != null) {
				let dt = now - prev.ts;

				if (dt > 0) {
					if (rx >= prev.rx_total)
						rec.rx_rate = int((rx - prev.rx_total) / dt);
					if (tx >= prev.tx_total)
						rec.tx_rate = int((tx - prev.tx_total) / dt);
				}
			}
		}

		push(found, rec);
	}

	sort(found, (a, b) => {
		if (a.name == b.name)
			return 0;

		/* wan first, then lan<n> numerically, then sfp */
		let rank = (n) => index(n, 'wan') == 0 ? 0 :
				 (index(n, 'lan') == 0 ? 1 : 2);

		if (rank(a.name) != rank(b.name))
			return rank(a.name) - rank(b.name);

		return a.name < b.name ? -1 : 1;
	});

	state.ports = found;
}

/* natflow keeps the per-client counters; it is the only source of a
 * per-client rate that x-wrt already ships.  Line format:
 *
 *   ip,mac,auth_type,auth_status,rule_id,idle_time,
 *   rx_pkts:rx_bytes,tx_pkts:tx_bytes,
 *   rx_speed_pkts:rx_speed_bytes,tx_speed_pkts:tx_speed_bytes,ifname
 */
function natflow_split(field) {
	let p = split(field ?? '', ':');

	return length(p) > 1 ? num(p[1]) : 0;
}

function clients_merge_natflow() {
	let text = readfile(NATFLOW_USERINFO);

	if (!text)
		return;

	let found = state.clients ?? {};

	for (let line in split(text, '\n')) {
		let f = split(trim(line), ',');

		if (length(f) < 10)
			continue;

		let mac = lc(trim(f[1]));
		let rec = found[mac];

		if (!rec) {
			rec = { mac, ip: trim(f[0]), hostname: null };
			found[mac] = rec;
		}

		if (!rec.ip)
			rec.ip = trim(f[0]);

		rec.rx_rate = natflow_split(f[8]);
		rec.tx_rate = natflow_split(f[9]);
		rec.rx_total = natflow_split(f[6]);
		rec.tx_total = natflow_split(f[7]);
		rec.ifname = trim(f[10] ?? '');
	}

	state.clients = found;
}

function clients_sort() {
	let out = [];

	for (let mac, rec in state.clients ?? {})
		push(out, rec);

	sort(out, (a, b) => {
		let an = a.hostname ?? a.mac;
		let bn = b.hostname ?? b.mac;

		return an < bn ? -1 : (an > bn ? 1 : 0);
	});

	state.clients = out;
}

function clients_read() {
	let found = {};
	let text = readfile('/tmp/dhcp.leases');

	for (let line in split(text ?? '', '\n')) {
		let f = words(line);

		if (length(f) < 4)
			continue;

		found[lc(f[1])] = {
			mac: lc(f[1]),
			ip: f[2],
			hostname: f[3] != '*' ? f[3] : null
		};
	}

	/* dhcpsnoop (x-wrt) knows about clients dnsmasq has forgotten */
	let dump = ubus_call('dhcpsnoop', 'dump');

	for (let mac, entry in dump ?? {}) {
		mac = lc(mac);

		if (found[mac])
			continue;

		let rec = { mac, ip: null, hostname: null };

		if (type(entry) == 'string')
			rec.ip = entry;
		else if (type(entry) == 'object')
			rec.ip = entry.ip;

		found[mac] = rec;
	}

	state.clients = found;
	clients_merge_natflow();
	clients_sort();
}

function band_of(freq) {
	if (!freq)
		return null;
	if (freq < 2500)
		return '2.4G';
	if (freq < 5900)
		return '5G';

	return '6G';
}

function security_of(enc) {
	if (!enc || enc == 'none')
		return 'Open';
	if (index(enc, 'sae') >= 0)
		return 'WPA3';
	if (index(enc, 'psk2') >= 0)
		return 'WPA2';
	if (index(enc, 'psk') >= 0)
		return 'WPA';
	if (index(enc, 'wep') >= 0)
		return 'WEP';

	return enc;
}

function wifi_read() {
	let status = ubus_call('network.wireless', 'status') ?? {};
	let running = {};

	for (let radio, st in status)
		for (let iface in st?.interfaces ?? [])
			if (iface.section)
				running[iface.section] = {
					ifname: iface.ifname,
					up: !!st.up
				};

	let found = [];
	let cursor = uci.cursor();

	cursor.foreach('wireless', 'wifi-iface', function(s) {
		if (!s.ssid)
			return;
		if (s.mode && s.mode != 'ap')
			return;

		let now = running[s['.name']] ?? {};
		let up = !truish(s.disabled) && now.up && now.ifname;
		let clients = 0;
		let freq = null;

		if (up) {
			let cl = ubus_call(sprintf('hostapd.%s', now.ifname),
					   'get_clients')?.clients;

			clients = cl ? length(cl) : 0;

			let info = ubus_call(sprintf('hostapd.%s', now.ifname),
					     'get_status');

			freq = info?.freq;
		}

		push(found, {
			ssid: s.ssid,
			band: band_of(freq),
			security: security_of(s.encryption),
			up: !!up,
			clients
		});
	});

	state.networks = found;
}

function clock_read() {
	let now = localtime(time());

	state.clock = sprintf('%02d:%02d', now.hour, now.min);
}

function rate_fmt(bytes) {
	if (bytes >= 1000000)
		return sprintf('%s MB/s', bytes >= 100000000
				       ? sprintf('%d', int(bytes / 1000000))
				       : sprintf('%.1f', int(bytes / 100000.0) / 10.0));
	if (bytes >= 100)
		return sprintf('%s KB/s', bytes >= 100000
				       ? sprintf('%d', int(bytes / 1000))
				       : sprintf('%.1f', int(bytes / 100.0) / 10.0));

	return sprintf('%d B/s', bytes);
}

/* compact form for table cells: 12.3M, 845K, 0 */
function rate_short(bytes) {
	if (bytes >= 10000000)
		return sprintf('%dM', int(bytes / 1000000));
	if (bytes >= 1000000)
		return sprintf('%.1fM', int(bytes / 100000.0) / 10.0);
	if (bytes >= 1000)
		return sprintf('%dK', int(bytes / 1000));
	if (bytes >= 100)
		return sprintf('%.1fK', int(bytes / 100.0) / 10.0);

	return sprintf('%d', bytes);
}

function row_rate(card, y, rx, tx) {
	let r = value_new(card, F_SMALL, C_RX, sprintf('↓%s', rate_short(rx ?? 0)));

	r.obj.set({ x: RIGHT_X, y: y, w: RIGHT_W });

	let t = value_new(card, F_SMALL, C_TX, sprintf('↑%s', rate_short(tx ?? 0)));

	t.obj.set({ x: RIGHT_X, y: y + ROW_SUB, w: RIGHT_W });
}

function total_fmt(bytes) {
	if (bytes >= 1000000000)
		return sprintf('%.2f GB', bytes / 1000000000.0);
	if (bytes >= 1000000)
		return sprintf('%.1f MB', bytes / 1000000.0);
	if (bytes >= 1000)
		return sprintf('%.1f KB', bytes / 1000.0);

	return sprintf('%d B', bytes);
}

function speed_fmt(mbps) {
	if (mbps == null)
		return '';

	if (mbps >= 2500)
		return sprintf('%sG', mbps % 1000
				     ? sprintf('%.1f', int(mbps / 100.0) / 10.0)
				     : sprintf('%d', int(mbps / 1000)));
	if (mbps >= 1000)
		return '1G';

	return sprintf('%dM', mbps);
}

function uptime_fmt(sec) {
	if (!sec)
		return '';

	let d = int(sec / 86400);
	let h = int((sec % 86400) / 3600);
	let m = int((sec % 3600) / 60);

	if (d > 0)
		return sprintf('%dd %02d:%02d', d, h, m);
	if (h > 0)
		return sprintf('%dh %02dm', h, m);

	return sprintf('%dm', m);
}

/*
 * 页面标题 + 紧跟其后的计数徽标。计数标签的 x 由标题宽度算出来，返回给调用者，
 * 之后直接 .text() 更新即可 —— 页面不必再自己算一遍坐标、也不会漏改标题串。
 */
function header_new(parent, title, count) {
	label_new(parent, F_TITLE, C_TXT, title).set({ x: HEAD_X, y: HEAD_TOP });

	let t = label_new(parent, F_SMALL, C_RULE, count ?? '');

	t.set({ x: HEAD_X + 4 + text_w(F_TITLE, title), y: HEAD_TOP + 8 });

	return t;
}

function bar_scaled(value, full, height) {
	if (full <= 0)
		return 0;

	let scaled = int(value * 1000 / full);

	if (scaled > 1000)
		scaled = 1000;

	let floor = int((2 * 1000 + height - 1) / height);

	return scaled > floor ? scaled : floor;
}

function usage_update() {
	let peak = 1;

	for (let v in state.rx)
		if (v > peak)
			peak = v;
	for (let v in state.tx)
		if (v > peak)
			peak = v;

	let bucket = peak * 1.25;

	if (bucket != usage.bucket) {
		usage.bucket = bucket;
		usage.chart.points(0, map(state.rx,
			v => bar_scaled(v, bucket, CHART_H)));
		usage.chart.points(1, map(state.tx,
			v => bar_scaled(v, bucket, CHART_H)));
	} else {
		usage.chart.push(0, bar_scaled(state.rx_rate, bucket, CHART_H));
		usage.chart.push(1, bar_scaled(state.tx_rate, bucket, CHART_H));
	}

	text_set(usage.rx_label, sprintf('↓ %s', rate_fmt(state.rx_rate)));
	text_set(usage.tx_label, sprintf('↑ %s', rate_fmt(state.tx_rate)));
	text_set(usage.total, sprintf('Total ↓ %s   ↑ %s',
				      total_fmt(state.rx_total),
				      total_fmt(state.tx_total)));
}

function system_update() {
	text_set(sys_pg.cpu, state.cpu != null ? sprintf('%d%%', state.cpu) : '--');
	sys_pg.cpu_bar.value(state.cpu ?? 0);

	text_set(sys_pg.load, state.load ?? '--');

	if (state.mem_total > 0) {
		let used = state.mem_total - state.mem_avail;

		text_set(sys_pg.mem, sprintf('%d / %d MB', int(used / 1048576),
					     int(state.mem_total / 1048576)));
		sys_pg.mem_bar.value(int(100 * used / state.mem_total));
	} else {
		text_set(sys_pg.mem, '--');
		sys_pg.mem_bar.value(0);
	}

	text_set(sys_pg.temp, state.temp != null ? sprintf('%d°C', state.temp) : '--');
	text_set(sys_pg.fan, state.fan != null ? sprintf('%d RPM', state.fan) : '--');
	text_set(sys_pg.uptime, uptime_fmt(state.uptime) || '--');
}

function clients_update() {
	let card = clients_pg.card;

	card.clean();

	clients_pg.count.text(sprintf('%d', length(state.clients)));

	if (!length(state.clients)) {
		empty_new(card, 'No clients');
		return;
	}

	let y = ROW_TOP;

	for (let c in state.clients) {
		let sub = c.hostname ? c.mac : (c.ip ?? '');

		if (c.ip && c.hostname)
			sub = sprintf('%s  %s', c.ip, c.mac);
		else if (c.ip && !c.hostname)
			sub = c.ip;

		row_main(card, y, c.hostname ?? c.mac, false);

		if (sub)
			row_sub(card, y, sub, false);

		/* 只有 natflow 认识的客户端才有速率，别给别的画一对 0 */
		if (c.rx_rate != null || c.tx_rate != null)
			row_rate(card, y, c.rx_rate, c.tx_rate);

		y += ROW_H;
		row_rule(card, y);
	}
}

function ports_update() {
	let card = ports_pg.card;

	card.clean();

	let up = 0;

	for (let p in state.ports)
		if (p.up)
			up++;

	ports_pg.count.text(sprintf('%d/%d', up, length(state.ports)));

	if (!length(state.ports)) {
		empty_new(card, 'No ports');
		return;
	}

	let y = ROW_TOP;

	for (let p in state.ports) {
		row_dot(card, y, p.up);
		row_main(card, y, p.name, true, 62);

		label_new(card, F_SMALL, p.up ? C_DIM : C_IDLE,
			  p.up ? (speed_fmt(p.speed) || 'link') : 'down')
			.set({ x: 96, y: y, w: 64 });

		if (p.up)
			row_rate(card, y, p.rx_rate, p.tx_rate);

		y += ROW_H;
		row_rule(card, y);
	}
}

function wifi_update() {
	let card = wifi_pg.card;

	card.clean();

	let total = 0;

	if (!length(state.networks)) {
		empty_new(card, 'No wireless networks');
		return;
	}

	let y = ROW_TOP;

	for (let n in state.networks) {
		total += n.clients;

		row_dot(card, y, n.up);
		row_main(card, y, n.ssid, true, 150);
		row_sub(card, y, sprintf('%s  %s', n.band ?? '?', n.security), true);
		row_value(card, y, sprintf('%d', n.clients),
			  n.clients ? C_TXT : C_DIM);

		y += ROW_H;
		row_rule(card, y);
	}

	label_new(card, F_SMALL, C_DIM,
		  sprintf('total %d station%s', total, total == 1 ? '' : 's'))
		.set({ x: ROW_X, y: y + 4 });
}

function dots_refresh() {
	for (let i = 0; i < length(dots); i++)
		dots[i].style({ bg_color: i == active ? C_DIM : C_IDLE });
}

function page_show(i, anim) {
	if (i == active)
		return;

	active = i;
	tileview.tile_set(i, 0, anim);
	dots_refresh();

	let p = pages[i];

	p.poll?.();
	p.update?.();
}

function touch_note() {
	last_touch = monotonic();

	if (blanked) {
		blanked = false;
		backlight_set(cfg.brightness);
		lv.touch_drop();
	}
}

/* card that scrolls vertically */
function card_new(parent, scroll) {
	let card = lv.obj(parent);

	card.set({ x: CARD_X, y: BODY_Y, w: CARD_W, h: BODY_H });
	card.style({ bg_color: C_SURFACE, radius: CARD_R, border_width: 0,
		     pad_all: 0, clip_corner: true });
	card.clickable(!!scroll);
	card.scrollable(!!scroll);
	card.scroll_dir(lv.DIR_VER);
	card.scrollbar(lv.SCROLLBAR_AUTO);
	card.on(lv.EVENT_PRESSED, touch_note);

	return card;
}

function usage_build(parent) {
	header_new(parent, 'Usage');

	let card = card_new(parent, false);

	usage.rx_label = text_new(card, F_MED, C_RX, '↓ 0 KB/s');
	usage.rx_label.obj.set({ x: ROW_X, y: GRID_TOP + 2 });

	usage.tx_label = text_new(card, F_MED, C_TX, '↑ 0 KB/s');
	usage.tx_label.obj.set({ x: ROW_X, y: GRID_TOP + 28 });

	usage.total = text_new(card, F_SMALL, C_DIM, '');
	usage.total.obj.set({ x: ROW_X, y: GRID_TOP + 54, w: ROW_W });
	usage.total.obj.long_mode(lv.LABEL_LONG_DOTS);

	let chart = lv.chart(card);

	chart.set({ x: ROW_X, y: CHART_Y, w: ROW_W, h: CHART_H });
	chart.chart_type(lv.CHART_TYPE_BAR);
	chart.point_count(POINTS);
	chart.update_mode(lv.CHART_UPDATE_SHIFT);
	chart.div_lines(0, 0);
	chart.scrollbar(lv.SCROLLBAR_OFF);
	chart.clickable(false);
	chart.scrollable(false);
	chart.style({ bg_opa: lv.OPA_TRANSP, border_width: 0, pad_all: 0,
		      pad_column: 2 });
	chart.style({ width: 0, height: 0 }, lv.PART_INDICATOR);
	chart.chart_range(0, 1000);
	chart.series(C_RX);
	chart.series(C_TX);
	chart.style({ bg_color: C_RX, bg_opa: lv.OPA_COVER, radius: 1 },
		    lv.PART_ITEMS);

	usage.chart = chart;
	usage.bucket = 1;
}

function system_build(parent) {
	header_new(parent, 'System');

	let card = card_new(parent, false);

	/* CPU：大字号百分比 + 进度条 */
	label_new(card, F_SMALL, C_DIM, 'CPU').set({ x: ROW_X, y: GRID_TOP + 8 });

	sys_pg.cpu = value_new(card, F_TITLE, C_TXT, '--');
	sys_pg.cpu.obj.set({ x: RIGHT_X, y: GRID_TOP, w: RIGHT_W });

	sys_pg.cpu_bar = bar_new(card, C_RX, 3);
	sys_pg.cpu_bar.set({ x: ROW_X, y: GRID_TOP + 34, w: ROW_W, h: 6 });

	/* 三行「标签 — 数值」，全部落在同一条网格上 */
	sys_pg.load = grid_row(card, 2, 'Load');
	sys_pg.mem = grid_row(card, 3, 'Memory');

	sys_pg.mem_bar = bar_new(card, C_TX, 3);
	sys_pg.mem_bar.set({ x: ROW_X, y: GRID_TOP + 3 * GRID_STEP + 22,
			    w: ROW_W, h: 6 });

	sys_pg.uptime = grid_row(card, 5, 'Uptime');

	/* 温度 / 风扇共用一行，两列对齐到同样的右边界 */
	let ty = GRID_TOP + 6 * GRID_STEP;

	label_new(card, F_SMALL, C_DIM, 'Temp').set({ x: ROW_X, y: ty + 3 });

	sys_pg.temp = value_new(card, F_SMALL, C_OK, '');
	sys_pg.temp.obj.set({ x: MID - 56, y: ty, w: 56 });

	label_new(card, F_SMALL, C_DIM, 'Fan').set({ x: MID + 12, y: ty + 3 });

	sys_pg.fan = value_new(card, F_SMALL, C_TX, '');
	sys_pg.fan.obj.set({ x: RIGHT_EDGE - 70, y: ty, w: 70 });
}

function clients_build(parent) {
	clients_pg.count = header_new(parent, 'Clients');
	clients_pg.card = card_new(parent, true);
}

function ports_build(parent) {
	ports_pg.count = header_new(parent, 'Ports');
	ports_pg.card = card_new(parent, true);
}

function wifi_build(parent) {
	header_new(parent, 'WiFi');
	wifi_pg.card = card_new(parent, true);
}

function tile_changed() {
	let now = tileview.tile_active()?.col ?? 0;

	touch_note();

	if (now == active)
		return;

	active = now;
	dots_refresh();

	let p = pages[active];

	p.poll?.();
	p.update?.();
}

function blank_check() {
	if (!cfg.blank || blanked)
		return;

	if (monotonic() - last_touch < cfg.blank * 60)
		return;

	blanked = true;
	backlight_set(0);
}

function dir_for(pos, count) {
	if (count < 2)
		return lv.DIR_NONE;
	if (pos == 0)
		return lv.DIR_RIGHT;
	if (pos == count - 1)
		return lv.DIR_LEFT;

	return lv.DIR_HOR;
}

function frame_build() {
	screen = lv.screen_create();

	screen.style({ bg_color: C_SCREEN, border_width: 0, pad_all: 0 });
	screen.scrollbar(lv.SCROLLBAR_OFF);
	screen.scrollable(false);
	screen.on(lv.EVENT_PRESSED, touch_note);

	let defs = [
		{ key: 'page_usage', name: 'usage',
		  build: usage_build, update: usage_update, poll: wan_read },
		{ key: 'page_system', name: 'system',
		  build: system_build, update: system_update, poll: sys_read },
		{ key: 'page_clients', name: 'clients',
		  build: clients_build, update: clients_update, poll: clients_read },
		{ key: 'page_ports', name: 'ports',
		  build: ports_build, update: ports_update, poll: ports_read },
		{ key: 'page_wifi', name: 'wifi',
		  build: wifi_build, update: wifi_update }
	];

	/* keep enabled pages only, so we know the count before tiling */
	let enabled = [];

	for (let d in defs) {
		if (cfg[d.key])
			push(enabled, d);
	}

	tileview = lv.tileview(screen);
	tileview.set({ x: 0, y: 0, w: W, h: H });
	tileview.style({ bg_opa: lv.OPA_TRANSP, border_width: 0, pad_all: 0 });
	tileview.scrollbar(lv.SCROLLBAR_OFF);
	tileview.on(lv.EVENT_VALUE_CHANGED, tile_changed);

	let count = length(enabled);

	for (let idx = 0; idx < count; idx++) {
		let d = enabled[idx];
		let tile = tileview.tile_add(idx, 0, dir_for(idx, count));

		tile.style({ bg_opa: lv.OPA_TRANSP, border_width: 0, pad_all: 0 });
		tile.scrollbar(lv.SCROLLBAR_OFF);
		tile.scrollable(false);
		tile.on(lv.EVENT_PRESSED, touch_note);

		d.build(tile);

		push(pages, { name: d.name, tile, update: d.update, poll: d.poll });
	}

	/* page dots */
	let left = int((W - ((count - 1) * 10 + 5)) / 2);

	for (let i = 0; i < count; i++) {
		let dot = box_new(screen, C_IDLE, 5);

		dot.set({ x: left + i * 10, y: H - 9, w: 5, h: 5 });
		push(dots, dot);
	}

	/* clock, top right */
	clock_label = text_new(screen, F_SMALL, C_DIM, '');

	clock_label.obj.set({ x: W - 52, y: HEAD_TOP + 6, w: 44 });
	clock_label.obj.style({ text_align: lv.TEXT_ALIGN_RIGHT });

	dots_refresh();

	/*
	 * 把建好的这块 screen 真正显示出来。
	 *
	 * lv.screen_create() 只是造了一个没有父对象的 screen，必须 lv.screen_load()
	 * 才会被渲染（见绑定层 KernelDoc）。少了这一句，六个页面连同启动画面会全部
	 * 画在一块永远不显示的内存上：屏上只有 LVGL 默认那块空白屏，而且因为默认屏
	 * 没有任何变化，之后连一次重绘都不会发生 —— 表现为"背光亮、屏全黑/全白、
	 * 死活不刷新"。
	 */
	lv.screen_load(screen);
}

function splash_hide() {
	if (!splash_obj)
		return;

	splash_obj.delete();
	splash_obj = null;
	lv.refresh();
}

function splash_check() {
	if (splash_obj && monotonic() >= splash_deadline)
		splash_hide();
}

function splash_show() {
	if (!cfg.splash)
		return;

	splash_obj = lv.obj(screen);
	splash_obj.set({ x: 0, y: 0, w: W, h: H });
	splash_obj.style({ bg_color: C_SCREEN, border_width: 0, pad_all: 0,
			   radius: 0 });
	splash_obj.clickable(true);
	splash_obj.on(lv.EVENT_PRESSED, splash_hide);

	let idx = null;

	try {
		idx = lv.image_load(LOGO_FILE, false);
	}
	catch (e) {
		idx = null;
	}

	let logo_h = 0;

	if (idx != null) {
		let img = lv.image(splash_obj);

		img.src(idx);
		img.set({ x: int((W - 128) / 2), y: 24 });
		logo_h = 128;
	}

	let title = label_new(splash_obj, F_TITLE, C_TXT, state.hostname);

	title.style({ text_align: lv.TEXT_ALIGN_CENTER });
	title.set({ x: 10, y: logo_h + 34, w: W - 20 });

	let sub = label_new(splash_obj, F_SMALL, C_DIM, 'x-wrt');

	sub.style({ text_align: lv.TEXT_ALIGN_CENTER });
	sub.set({ x: 10, y: logo_h + 62, w: W - 20 });

	splash_deadline = monotonic() + cfg.splash;
}

/* ------------------------------------------------------------------ */
/* 主流程 */
/* ------------------------------------------------------------------ */

config_read();
backlight_find();
backlight_set(cfg.brightness);

if (!lv.init())
	die('cannot initialise LVGL');

if (!lv.display_drm(getenv('PANEL_DRM_DEVICE') ?? '/dev/dri/card0', -1))
	die('cannot open the DRM display');

if (touch_device)
	lv.indev_evdev(touch_device);

fonts_load();

let sysinfo = ubus_call('system', 'board');

state.hostname = sysinfo?.hostname ?? 'openwrt';

uloop.init();

frame_build();

if (!length(pages))
	die('no pages enabled in /etc/config/xwrt_panel');

/* first fill */
wan_device_read();
wan_read();
sys_read();
ports_read();
clients_read();
wifi_read();
clock_read();

pages[0].update?.();
text_set(clock_label, state.clock);

splash_show();

lv.refresh();

last_touch = monotonic();

uloop.interval(1000, function() {
	wan_read();
	sys_read();
	clock_read();

	let p = pages[active];

	if (p.name != 'usage' && p.name != 'system')
		p.poll?.();

	text_set(clock_label, state.clock);
	p.update?.();
	splash_check();
	lv.refresh();
});

uloop.interval(5000, function() {
	ports_read();
		clients_read();
	wifi_read();

	if (pages[active].name != 'usage')
		pages[active].update?.();

	lv.refresh();
});

uloop.interval(1000, function() {
	blank_check();

	if (splash_obj)
		return;

	if (!cfg.rotate || blanked)
		return;

	if (++rotate_tick < cfg.rotate)
		return;

	rotate_tick = 0;
	page_show((active + 1) % length(pages), true);
	lv.refresh();
});

/*
 * LVGL 心跳：必须周期性调用 lv.timer_handler()。
 *
 * 它负责三件事 —— 推进 LVGL 的动画、读取触摸输入、把待重绘区域真正画出来。
 * 只调 lv.refresh() 的话，静态的数值刷新看着正常，但翻页动画和触摸输入
 * 都会失灵（lv_refr_now() 只是把当前状态渲染一遍，不会推进任何东西）。
 */
uloop.interval(50, function() {
	lv.timer_handler();
});

ubus.listener('network.interface', function() {
	wan_device_read();
});

uloop.run();
