window.addEventListener('DOMContentLoaded', event => {
	document.querySelectorAll('details#avenza').forEach(details => {
		details.addEventListener('toggle', event => {
			const mapboxLoaded = new Promise(resolve => {
				const script = document.createElement('script');
				document.head.append(script);
				script.addEventListener('load', resolve, false);
				script.src = 'https://api.mapbox.com/mapbox.js/v3.3.1/mapbox.js';
			});
			const xhr = new XMLHttpRequest();
			const jsonLoaded = new Promise(resolve => {
				xhr.responseType = 'json';
				xhr.addEventListener('load', resolve, false);
				xhr.open('GET', 'maps.json'), xhr.send();
			});
			Promise.all([mapboxLoaded, jsonLoaded]).then(events => {
				if (xhr.status != 200) return;
				const sheets = xhr.response.features.map(feature => {
					return {
						type: feature['properties']['type'],
						url: feature['properties']['url'],
						state: feature['properties']['state'],
						title: feature['properties']['title'],
						corners: feature['geometry']['coordinates'][0].map(pair => pair.reverse()),
					};
				});
				const bounds = L.latLngBounds(sheets[0].corners);
				sheets.forEach(sheet => sheet.corners.forEach(point => bounds.extend(point)));
				L.mapbox.accessToken = 'pk.eyJ1IjoibWhvbGxpbmciLCJhIjoiY2pncms3d3plMDY3ODJ2bnh0YWdydTBwYyJ9.RdmqeL6b_5m8Q-SzQdbXuQ';
				const layer = L.mapbox.styleLayer('mapbox://styles/mholling/ck9bz5uth02671imzx2s7jujc');
				const map = L.mapbox.map('map').fitBounds(bounds).setMaxBounds(bounds.pad(0.2)).addLayer(layer);
				const div = details.querySelector('.map');
				const types = ['bundle', '50k', '40k', '25k'];
				const states = sheets.reduce((memo, sheet) => memo.add(sheet.state), new Set());
				types.forEach(type => states.forEach(state => map.createPane(type + ',' + state)));
				const addToggle = (toggle, klass) => {
					const label = document.createElement('label');
					const input = document.createElement('input');
					input.id = 'show-' + toggle;
					input.type = 'checkbox';
					input.checked = true;
					label.appendChild(input);
					label.append(toggle);
					div.querySelector('fieldset.' + klass).appendChild(label);
					label.querySelector('input').addEventListener('change', event => {
						Object.keys(map.getPanes()).forEach(key => {
							keys = key.split(',');
							if (!keys.includes(toggle))
								return;
							if (keys.every(key => div.querySelector('#show-' + key).checked))
								map.getPane(key).removeAttribute('hidden');
							else
								map.getPane(key).setAttribute('hidden', '');
						});
					});
				};
				types.forEach(type => addToggle(type, 'types'));
				Array.from(states).filter(state => !state.includes(',')).forEach(state => addToggle(state, 'states'));
				const qrCodeContainer = document.getElementById('qrcode');
				const qrCodeControl = L.control({position: 'bottomleft'});
				qrCodeControl.onAdd = map => qrCodeContainer;
				qrCodeControl.addTo(map);
				sheets.forEach(sheet => {
					const weight = sheet.type === 'bundle' ? 2 : 1;
					L.polygon(sheet.corners, {
						color: sheet.type === '25k' ? '#FF0000' : sheet.type === '40k' ? '#800080' : sheet.type === '50k' ? '#0000FF' : '#000000',
						weight: weight,
						opacity: 0.8,
						fillOpacity: 0.05,
						pane: sheet.type + ',' + sheet.state,
					}).on('click', event => {
						window.open(sheet.url);
					}).on('mouseover', event => {
						event.target.setStyle({weight: 4});
						if ('ontouchstart' in document.documentElement) return;
						new QRCode(qrCodeContainer, {text: sheet.url, width: 128, height: 128});
					}).on('mouseout', event => {
						event.target.setStyle({weight: weight});
						if ('ontouchstart' in document.documentElement) return;
						qrCodeContainer.innerHTML = null;
					}).bindTooltip(sheet.title, {
						direction: 'top',
						opacity: 0.9,
						sticky: true,
					}).addTo(map);
				});
			});
		}, {once: true});
	});

	const defaultTitle = document.title;
	document.querySelectorAll('details').forEach(details => {
		const hash = '#' + details.id;
		const title = "nswtopo | " + details.querySelector('summary').innerText;
		const others = document.querySelectorAll('details:not(' + hash + ')');
		if (hash == location.hash)
			details.setAttribute('open', '');
		window.addEventListener('hashchange', event => {
			if (hash == location.hash)
				details.setAttribute('open', '');
			else
				details.removeAttribute('open');
		});
		details.addEventListener('toggle', event => {
			const allClosed = !details.open && !document.querySelector('details[open]');
			if (details.open)
				others.forEach(other => other.removeAttribute('open'));
			if (details.open ? location.hash != hash : location.hash && allClosed)
				history.pushState(null, '', details.open ? location.pathname + hash : location.pathname);
			if (details.open)
				document.title = title;
			else if (allClosed)
				document.title = defaultTitle;
		});
	});

	document.querySelectorAll('a.obf').forEach(anchor => {
		anchor.appendChild(document.createTextNode(atob('aW5mb0Buc3d0b3BvLmNvbQ==')));
		anchor.setAttribute('href', atob('bWFpbHRvOmluZm9AbnN3dG9wby5jb20='));
	});

	document.querySelectorAll('div.carousel').forEach(div => {
		var start;
		div.querySelector('ul.slides').addEventListener('touchstart', event => start = start ? null : event);
		div.querySelector('ul.slides').addEventListener('touchend', event => {
			if (!start)
				return;
			const dx = event.changedTouches[0].screenX - start.changedTouches[0].screenX;
			const dy = event.changedTouches[0].screenY - start.changedTouches[0].screenY;
			start = null;
			if (Math.abs(dy) > Math.abs(dx))
				return;
			if (dx < 0)
				var target = div.querySelector('input:checked + input');
			else if (dx > 0)
				var target = div.querySelector('input:checked').previousElementSibling;
			if (target)
				target.checked = true;
		});
	});
});
