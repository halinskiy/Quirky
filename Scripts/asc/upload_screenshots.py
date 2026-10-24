"""Upload Scripts/appstore/[0-9]-*.png as Mac (APP_DESKTOP) screenshots, replacing the set."""
import asc, requests, hashlib, os, glob, time
VER = asc.get('/apps/6773094144/appStoreVersions')['data'][0]['id']
loc = asc.get(f'/appStoreVersions/{VER}/appStoreVersionLocalizations')['data'][0]['id']
sets = asc.get(f'/appStoreVersionLocalizations/{loc}/appScreenshotSets')['data']
s = next((x for x in sets if x['attributes']['screenshotDisplayType'] == 'APP_DESKTOP'), None)
if s:
    for shot in asc.get(f"/appScreenshotSets/{s['id']}/appScreenshots")['data']:
        requests.delete(asc.API + f"/appScreenshots/{shot['id']}", headers=asc.H())
else:
    s = asc.post('/appScreenshotSets', {'data': {'type': 'appScreenshotSets', 'attributes': {'screenshotDisplayType': 'APP_DESKTOP'},
        'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': loc}}}}})['data']
for path in sorted(glob.glob(os.path.join(os.path.dirname(__file__), '../appstore/[0-9]-*.png'))):
    data = open(path, 'rb').read()
    r = asc.post('/appScreenshots', {'data': {'type': 'appScreenshots', 'attributes': {'fileName': os.path.basename(path), 'fileSize': len(data)},
        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': s['id']}}}}})['data']
    for op in r['attributes']['uploadOperations']:
        chunk = data[op['offset']:op['offset'] + op['length']]
        requests.request(op['method'], op['url'], data=chunk, headers={h['name']: h['value'] for h in op['requestHeaders']}).raise_for_status()
    asc.patch(f"/appScreenshots/{r['id']}", {'data': {'type': 'appScreenshots', 'id': r['id'],
        'attributes': {'uploaded': True, 'sourceFileChecksum': hashlib.md5(data).hexdigest()}}})
    print('uploaded', os.path.basename(path))
time.sleep(15)
for shot in asc.get(f"/appScreenshotSets/{s['id']}/appScreenshots")['data']:
    print(shot['attributes']['fileName'], shot['attributes']['assetDeliveryState']['state'])
