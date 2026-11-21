#!/usr/bin/env python3
"""Non-blocking public VirusTotal scan report for a published signed Android APK.

The caller supplies only a public release APK. Never pass signing keys, private
user files, or local backups here. API key is read from VIRUSTOTAL_API_KEY.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
from datetime import datetime, timezone
from urllib.parse import quote, urlsplit, urlunsplit

API = 'https://www.virustotal.com/api/v3'
MAX_BYTES = 650 * 1000 * 1000
SMALL_BYTES = 32 * 1000 * 1000
REPORT_BASE = 'https://www.virustotal.com/gui/file/'


def file_sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def issue_request(session, method, url, **kwargs):
    kwargs.setdefault('timeout', (20, 90))
    kwargs.setdefault('allow_redirects', False)
    response = session.request(method, url, **kwargs)
    # Never silently send the API key to a redirected destination.
    if 300 <= response.status_code < 400:
        raise ValueError('VirusTotal redirected a request unexpectedly')
    return response


def checked_json(response):
    if response.status_code == 429:
        raise RuntimeError('rate_limited')
    if response.status_code in (401, 403):
        raise RuntimeError('api_access_denied')
    if response.status_code >= 400:
        raise RuntimeError('VirusTotal request failed (HTTP %s)' % response.status_code)
    data = response.json()
    if not isinstance(data, dict):
        raise ValueError('VirusTotal returned invalid JSON')
    return data


def upload_endpoint(session, size):
    if size <= SMALL_BYTES:
        return API + '/files'
    response = issue_request(session, 'GET', API + '/files/upload_url')
    endpoint = checked_json(response).get('data', '')
    if not isinstance(endpoint, str):
        raise ValueError('Invalid large-file upload URL')
    parts = urlsplit(endpoint)
    host = (parts.hostname or '').lower()
    if host != 'virustotal.com' and not host.endswith('.virustotal.com'):
        raise ValueError('Upload URL did not belong to VirusTotal')
    if parts.scheme not in ('http', 'https') or parts.username or parts.password:
        raise ValueError('Untrusted VirusTotal upload URL')
    # Public docs show an HTTP example. Always require TLS for actual uploads.
    return urlunsplit(('https', parts.netloc, parts.path, parts.query, ''))


def scan(apk, key, wait_seconds):
    outcome = {
        'schemaVersion': 1,
        'apk': apk.name,
        'sizeBytes': apk.stat().st_size,
        'sha256': file_sha256(apk),
        'checkedAtUtc': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'status': 'unavailable',
        'source': '',
        'reportUrl': '',
        'analysisStats': {},
    }
    outcome['reportUrl'] = REPORT_BASE + outcome['sha256'] + '/detection'
    if outcome['sizeBytes'] == 0:
        outcome.update(status='invalid_apk', message='APK was empty')
        return outcome
    if outcome['sizeBytes'] > MAX_BYTES:
        outcome.update(status='too_large', message='APK is larger than the 650 MB VirusTotal limit')
        return outcome
    if not key:
        outcome.update(status='not_configured', message='Set the repository secret VIRUSTOTAL_API_KEY to enable scanning')
        return outcome

    import requests  # Installed by GitHub Actions only for the scanner job.
    session = requests.Session()
    session.headers.update({'x-apikey': key, 'Accept': 'application/json', 'User-Agent': 'SpicyChat-QoL-Android-VT/1'})
    try:
        existing = issue_request(session, 'GET', API + '/files/' + outcome['sha256'])
        if existing.status_code == 200:
            attrs = (checked_json(existing).get('data') or {}).get('attributes') or {}
            stats = attrs.get('last_analysis_stats') or {}
            if isinstance(stats, dict) and stats and attrs.get('last_analysis_date'):
                outcome.update(status='completed', source='existing_sha256_report', analysisStats=stats)
                return outcome
            outcome.update(status='pending', source='existing_sha256_report', message='Existing file record has no completed analysis statistics')
            return outcome
        if existing.status_code != 404:
            checked_json(existing)
            raise RuntimeError('Unexpected VirusTotal file lookup status')

        endpoint = upload_endpoint(session, outcome['sizeBytes'])
        # Requests' multipart files argument buffers the file in memory. It is
        # suitable for this project's roughly 50 MB APK releases. A future
        # >200 MB release should switch to a streaming multipart uploader.
        with apk.open('rb') as source:
            uploaded = issue_request(
                session, 'POST', endpoint,
                files={'file': (apk.name, source, 'application/vnd.android.package-archive')},
                timeout=(30, 900),
            )
        analysis = checked_json(uploaded)
        analysis_id = (analysis.get('data') or {}).get('id', '')
        if not isinstance(analysis_id, str) or not analysis_id or len(analysis_id) > 512:
            raise ValueError('VirusTotal did not provide an analysis ID')
        outcome.update(status='pending', source='new_upload', message='APK uploaded; analysis pending')
        # The public API has strict rate limits. Delay the first status check
        # for >60 seconds after the initial lookup / upload-URL / upload calls.
        deadline = time.monotonic() + max(0, wait_seconds)
        delay = 65
        while time.monotonic() + delay <= deadline:
            time.sleep(delay)
            latest = checked_json(issue_request(session, 'GET', API + '/analyses/' + quote(analysis_id, safe='')))
            attrs = (latest.get('data') or {}).get('attributes') or {}
            if attrs.get('status') == 'completed':
                stats = attrs.get('stats') or {}
                if not isinstance(stats, dict):
                    raise ValueError('Invalid VirusTotal analysis statistics')
                outcome.update(status='completed', analysisStats=stats, message='Analysis completed')
                return outcome
            delay = 30
        return outcome
    except RuntimeError as exc:
        # The exported JSON is public. Avoid echoing API keys or single-use
        # upload URLs, including those embedded in HTTP exception messages.
        code = str(exc)
        if code in ('rate_limited', 'api_access_denied'):
            outcome.update(status=code, message='VirusTotal API quota or access prevented scanning')
        else:
            outcome.update(status='unavailable', message='VirusTotal could not complete the scan')
        return outcome
    except Exception:
        outcome.update(status='unavailable', message='VirusTotal scan request failed; retry after checking API availability')
        return outcome
    finally:
        session.close()


def markdown(report):
    status = report['status']
    counts = report.get('analysisStats') or {}
    rows = [
        '## VirusTotal check for signed Android APK',
        '',
        '- **APK:** %s' % report['apk'],
        '- **SHA-256:** %s' % report['sha256'],
        '- **Status:** %s' % status,
    ]
    if status == 'completed':
        rows += [
            '- **Malicious detections:** %s' % int(counts.get('malicious', 0)),
            '- **Suspicious detections:** %s' % int(counts.get('suspicious', 0)),
            '- **Harmless / undetected:** %s / %s' % (int(counts.get('harmless', 0)), int(counts.get('undetected', 0))),
            '- **Report:** [VirusTotal file results](%s)' % report['reportUrl'],
        ]
        if int(counts.get('malicious', 0)) or int(counts.get('suspicious', 0)):
            rows.append('- **Attention:** One or more engines flagged this file; review before drawing conclusions.')
    else:
        rows.append('- **Details:** %s' % report.get('message', 'No completed result is available'))
    rows += ['', '_VirusTotal detections are indicators, not proof of safety or maliciousness. This independent job does not block publication._', '']
    return '\n'.join(rows)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('apk', type=Path)
    parser.add_argument('--json-out', required=True, type=Path)
    parser.add_argument('--summary-out', required=True, type=Path)
    parser.add_argument('--wait-seconds', type=int, default=300)
    args = parser.parse_args()
    if not args.apk.is_file():
        parser.error('APK file does not exist')
    result = scan(args.apk, os.environ.get('VIRUSTOTAL_API_KEY', '').strip(), args.wait_seconds)
    args.json_out.write_text(json.dumps(result, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    args.summary_out.write_text(markdown(result), encoding='utf-8')
    print('VirusTotal status:', result['status'])
    print('APK SHA256:', result['sha256'])
    # Even API errors are reported as a separate non-blocking scan outcome.
    return 0


if __name__ == '__main__':
    sys.exit(main())
