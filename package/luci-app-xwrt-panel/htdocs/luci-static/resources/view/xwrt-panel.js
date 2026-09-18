'use strict';
'require view';
'require form';
'require ui';
'require rpc';

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

var callInitAction = rpc.declare({
	object: 'rc',
	method: 'init',
	params: [ 'name', 'action' ],
	expect: { result: false }
});

/* Brightness slider: range input synced with a number box, writing UCI
 * like an ordinary form.Value. */
var SliderValue = form.Value.extend({
	renderWidget: function(section_id, option_index, cfgvalue) {
		var value = (cfgvalue != null && cfgvalue !== '') ? +cfgvalue : 80;

		var range = E('input', {
			type: 'range', min: '10', max: '100', step: '1',
			value: String(value),
			style: 'width: 220px; vertical-align: middle',
			id: this.cbid(section_id),
			name: this.cbid(section_id),
			'data-widget': 'cbi-slider'
		});

		var num = E('input', {
			type: 'number', min: '10', max: '100',
			value: String(value),
			class: 'cbi-input-text',
			style: 'width: 5em; margin-left: 0.5em',
			readonly: 'readonly'
		});

		range.addEventListener('input', function() {
			num.value = range.value;
			range.dispatchEvent(new Event('change', { bubbles: true }));
		});

		return E('div', {}, [ range, num, ' %' ]);
	},

	remove: function() {}, /* brightness always has a sane value */
});

return view.extend({
	callInit: function(action) {
		return callInitAction('xwrt-panel', action).then(function(ok) {
			ui.addNotification(null,
				E('p', _('Service action "%s" %s').format(action,
					ok ? _('succeeded') : _('failed'))),
				ok ? 'info' : 'error');
			return ok;
		});
	},

	render: function(res) {
		var svc = res && res['xwrt-panel'];
		var running = !!(svc && svc.instances &&
			Object.keys(svc.instances).length);

		var m, s, o;

		m = new form.Map('xwrt_panel',
			_('Statistics Panel Screen'),
			_('Settings for the minimal statistics panel (xwrt-panel) '
			  + 'of the GL-BE10000 / GL-BE14000. The panel shows WAN '
			  + 'usage, system state, clients with their rate, port '
			  + 'links, WAN interfaces and WiFi status. Changes are '
			  + 'applied to /etc/config/xwrt_panel and the panel '
			  + 'service is restarted on "Save & Apply".'));

		/* ---- status & service control ---------------------------- */
		s = m.section(form.TypedSection, 'panel', _('Panel service'));
		s.anonymous = true;

		o = s.option(form.DummyValue, '_status', _('Service state'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return running
				? '<span style="color:#3a7">&bull; ' + _('running') + '</span>'
				: '<span style="color:#c33">&bull; ' + _('not running') + '</span>';
		};

		o = s.option(form.Button, '_restart', _('Control'));
		o.inputtitle = _('Restart panel');
		o.inputstyle = 'apply';
		o.onclick = L.bind(this.callInit, this, 'restart');

		o = s.option(form.Button, '_stop', '');
		o.inputtitle = _('Stop');
		o.inputstyle = 'remove';
		o.onclick = L.bind(this.callInit, this, 'stop');

		/* ---- display -------------------------------------------- */
		s = m.section(form.TypedSection, 'panel', _('Display'));
		s.anonymous = true;

		o = s.option(SliderValue, 'brightness', _('Brightness'),
			_('Panel backlight brightness, 10 to 100 percent.'));
		o.default = '80';
		o.rmempty = false;

		o = s.option(form.Value, 'rotate', _('Page rotation (s)'),
			_('Automatically switch to the next page every N seconds. '
			  + 'Set to 0 to only change pages by swiping.'));
		o.datatype = 'range(0,3600)';
		o.default = '0';
		o.placeholder = '0';

		o = s.option(form.Value, 'splash', _('Boot logo (s)'),
			_('Seconds the x-wrt mark stays on the panel while the '
			  + 'service starts up. A touch clears it right away. '
			  + 'Set to 0 to skip the splash.'));
		o.datatype = 'range(0,60)';
		o.default = '3';
		o.placeholder = '3';

		o = s.option(form.Value, 'blank', _('Blank after (min)'),
			_('Minutes without touch before the backlight turns off. '
			  + 'Set to 0 to keep the screen always on. Any touch '
			  + 'wakes the panel.'));
		o.datatype = 'range(0,1440)';
		o.default = '5';
		o.placeholder = '5';

		/* ---- pages ---------------------------------------------- */
		s = m.section(form.TypedSection, 'panel', _('Pages'),
			_('At least one page must stay enabled.'));

		o = s.option(form.Flag, 'page_usage', _('Usage'),
			_('WAN up/down rates, totals and a scrolling rate graph.'));
		o.default = '1';
		o.enabled = '1';
		o.disabled = '0';

		o = s.option(form.Flag, 'page_system', _('System'),
			_('CPU load, memory, SoC temperature, fan speed and '
			  + 'uptime.'));
		o.default = '1';
		o.enabled = '1';
		o.disabled = '0';

		o = s.option(form.Flag, 'page_clients', _('Clients'),
			_('DHCP leases and snooped clients, with the per-client '
			  + 'rate reported by natflow.'));
		o.default = '1';
		o.enabled = '1';
		o.disabled = '0';

		o = s.option(form.Flag, 'page_ports', _('Ports'),
			_('Link state and negotiated speed of every wan/lan/sfp '
			  + 'port, with its current rate.'));
		o.default = '1';
		o.enabled = '1';
		o.disabled = '0';

		o = s.option(form.Flag, 'page_wifi', _('WiFi'),
			_('Wireless networks with band, encryption and station '
			  + 'count.'));
		o.default = '1';
		o.enabled = '1';
		o.disabled = '0';

		return m.render();
	},

	load: function() {
		return L.resolveDefault(callServiceList('xwrt-panel'), {});
	}
});
