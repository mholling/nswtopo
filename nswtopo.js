window.addEventListener('DOMContentLoaded', event => {
	document.querySelectorAll('details#avenza').forEach(avenza => {
		avenza.addEventListener('toggle', event => {
			var mapboxLoaded = new Promise(resolve => {
				var script = document.createElement('script');
				document.head.append(script);
				script.addEventListener('load', resolve, false);
				script.src = 'https://api.mapbox.com/mapbox.js/v3.3.1/mapbox.js';
			});
			var xhr = new XMLHttpRequest();
			var jsonLoaded = new Promise(resolve => {
				xhr.addEventListener('load', resolve, false);
				xhr.open('GET', 'maps.json');
				xhr.send();
			});
			Promise.all([mapboxLoaded, jsonLoaded]).then(events => {
				if (xhr.status != 200) return;
				var sheets = JSON.parse(xhr.responseText).features.map(feature => {
					return {
						type: feature['properties']['type'],
						url: feature['properties']['url'],
						state: feature['properties']['state'],
						title: feature['properties']['title'],
						corners: feature['geometry']['coordinates'][0].map(pair => pair.reverse()),
					};
				});
				var states = [], types = ['bundle', '50k', '40k', '25k'];
				var bounds = L.latLngBounds(sheets[0].corners);
				sheets.forEach(sheet => {
					sheet.corners.forEach(point => bounds.extend(point));
					if (states.indexOf(sheet.state) < 0)
						states.push(sheet.state);
				});
				L.mapbox.accessToken = 'pk.eyJ1IjoibWhvbGxpbmciLCJhIjoiY2pncms3d3plMDY3ODJ2bnh0YWdydTBwYyJ9.RdmqeL6b_5m8Q-SzQdbXuQ';
				var layer = L.mapbox.styleLayer('mapbox://styles/mholling/ck9bz5uth02671imzx2s7jujc');
				var map = L.mapbox.map('map').fitBounds(bounds).setMaxBounds(bounds.pad(0.2)).addLayer(layer);
				types.forEach(type => states.forEach(state => map.createPane(type + ',' + state)));
				states = states.filter(state => !state.includes(','));
				types.concat(states).forEach(type => {
					var element = document.createElement('div');
					element.textContent = type;
					element.id = 'show-' + type;
					element.classList.add('selected');
					document.getElementById('toggles').appendChild(element);
					element.addEventListener('click', event => {
						element.classList.toggle('selected');
						Object.keys(map.getPanes()).forEach(key => {
							keys = key.split(',');
							if (!keys.includes(type)) return;
							var selected = keys.every(key => document.getElementById('show-' + key).classList.contains('selected'));
							map.getPane(key).style.display = selected ? 'block' : 'none';
						});
					});
				});
				var toggles = L.control({position: 'topright'});
				toggles.onAdd = map => document.getElementById('toggles');
				toggles.addTo(map);
				var qrcode = L.control({position: 'bottomleft'});
				qrcode.onAdd = map => document.getElementById('qrcode');
				qrcode.addTo(map);
				sheets.forEach(sheet => {
					var weight = sheet.type === 'bundle' ? 2 : 1;
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
						new QRCode(document.getElementById('qrcode'), {text: sheet.url, width: 128, height: 128});
					}).on('mouseout', event => {
						event.target.setStyle({weight: weight});
						if ('ontouchstart' in document.documentElement) return;
						document.getElementById('qrcode').innerHTML = null;
					}).bindTooltip(sheet.title, {
						direction: 'top',
						opacity: 0.9,
						sticky: true,
					}).addTo(map);
				});
			});
		}, {once: true});
	});

	var default_title = document.title;
	document.querySelectorAll('details').forEach(details => {
		var hash = '#' + details.id;
		var title = "nswtopo: " + details.querySelector('summary').innerText;
		var others = document.querySelectorAll('details:not(' + hash + ')');
		if (hash == location.hash)
			details.setAttribute('open', '');
		window.addEventListener('hashchange', event => {
			if (hash == location.hash)
				details.setAttribute('open', '');
			else
				details.removeAttribute('open');
		});
		details.addEventListener('toggle', event => {
			var all_closed = !details.open && !document.querySelector('details[open]');
			if (details.open)
				others.forEach(other => other.removeAttribute('open'));
			if (details.open ? location.hash != hash : location.hash && all_closed)
				history.pushState(null, '', details.open ? location.pathname + hash : location.pathname);
			details.open ? document.title = title : all_closed ? document.title = default_title : null;
		});
	});

	document.querySelectorAll('span.obf').forEach(span => {
		var anchor = document.createElement('a');
		anchor.appendChild(document.createTextNode(atob('aW5mb0Buc3d0b3BvLmNvbQ==')));
		anchor.setAttribute('href', atob('bWFpbHRvOmluZm9AbnN3dG9wby5jb20='));
		span.appendChild(anchor);
	});
});
