#!/usr/bin/env python3
"""Посредник API сервисов на шлюзе: ключи из /etc/ticket-services, allow-list маршрутов, остальное 403."""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, urlsplit

CREDENTIALS_DIR = Path('/etc/ticket-services')
LISTEN = ('0.0.0.0', 8080)
BODY_LIMIT = 1024 * 1024
TIMEOUT = 120

REDMINE_ROUTES = [
    ('GET', re.compile(r'^/issues/\d+\.json(\?.*)?$')),
    ('GET', re.compile(r'^/issues\.json(\?.*)?$')),
    ('GET', re.compile(r'^/attachments/download/\d+/.+$')),
    ('GET', re.compile(r'^/issue_statuses\.json$')),
    ('GET', re.compile(r'^/users/current\.json$')),
    ('GET', re.compile(r'^/custom_fields\.json$')),
    ('PUT', re.compile(r'^/issues/\d+\.json$')),
]
GITLAB_SHARED = [
    ('GET', re.compile(r'^/api/v4/users\?username=[^&]+$')),
    ('GET', re.compile(r'^/api/v4/version$')),
]
GITHUB_API = 'https://api.github.com'
CODEHOST_ENV_KEYS = ('CODEHOST_KIND', 'CODEHOST_URL', 'CODEHOST_API_URL', 'CODEHOST_PROJECT')
GITHUB_REPO_SETTINGS = {'delete_branch_on_merge'}


@dataclass
class TicketHost:
    url: str
    key: str


@dataclass
class CodeProject:
    url: str
    project: str
    token: str

    def routes(self) -> list[tuple[str, re.Pattern]]:
        identifier = re.escape(quote(self.project, safe=''))
        return [
            ('GET', re.compile(rf'^/api/v4/projects/{identifier}/merge_requests(\?.*)?$')),
            ('POST', re.compile(rf'^/api/v4/projects/{identifier}/merge_requests$')),
            ('PUT', re.compile(rf'^/api/v4/projects/{identifier}/merge_requests/\d+$')),
        ]


@dataclass
class GitHubProject:
    api: str
    project: str
    token: str

    def repository(self) -> re.Pattern:
        return re.compile(rf'^/repos/{re.escape(self.project)}$')

    def routes(self) -> list[tuple[str, re.Pattern]]:
        pulls = rf'^/repos/{re.escape(self.project)}/pulls'
        return [
            ('GET', self.repository()),
            ('GET', re.compile(rf'{pulls}(\?.*)?$')),
            ('POST', re.compile(rf'{pulls}$')),
            ('PATCH', re.compile(rf'{pulls}/\d+$')),
            ('POST', re.compile(rf'{pulls}/\d+/requested_reviewers$')),
        ]

    def headers(self) -> dict[str, str]:
        return {'Authorization': f'Bearer {self.token}', 'Accept': 'application/vnd.github+json',
                'X-GitHub-Api-Version': '2022-11-28'}


def read_env(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        values[key.strip()] = value.strip()
    return values


def is_github(values: dict[str, str]) -> bool:
    kind = values.get('CODEHOST_KIND', '').lower()
    return kind == 'github' or (not kind and urlsplit(values['CODEHOST_URL']).hostname == 'github.com')


def load_services() -> tuple[TicketHost | None, list[CodeProject], list[GitHubProject]]:
    tickethost = None
    projects = []
    github_projects = []
    container_defaults = {key: os.environ[key] for key in CODEHOST_ENV_KEYS if os.environ.get(key)}
    for path in sorted(CREDENTIALS_DIR.glob('*.env')):
        values = {**container_defaults, **read_env(path)}
        if tickethost is None and values.get('TICKETHOST_URL') and values.get('TICKETHOST_API_KEY'):
            tickethost = TicketHost(values['TICKETHOST_URL'].rstrip('/'), values['TICKETHOST_API_KEY'])
        if not (values.get('CODEHOST_URL') and values.get('CODEHOST_PROJECT') and values.get('CODEHOST_TOKEN')):
            continue
        if is_github(values):
            api = values.get('CODEHOST_API_URL', GITHUB_API).rstrip('/')
            github_projects.append(GitHubProject(api, values['CODEHOST_PROJECT'], values['CODEHOST_TOKEN']))
        else:
            projects.append(CodeProject(values['CODEHOST_URL'].rstrip('/'), values['CODEHOST_PROJECT'],
                                        values['CODEHOST_TOKEN']))
    return tickethost, projects, github_projects


def allowed(method: str, path: str, routes: list[tuple[str, re.Pattern]]) -> bool:
    return any(method == route_method and pattern.match(path) for route_method, pattern in routes)


def repository_settings_allowed(body: bytes) -> bool:
    try:
        settings = json.loads(body or b'{}')
    except ValueError:
        return False
    return isinstance(settings, dict) and bool(settings) and set(settings) <= GITHUB_REPO_SETTINGS


class Broker(BaseHTTPRequestHandler):
    tickethost: TicketHost | None = None
    projects: list[CodeProject] = []
    github_projects: list[GitHubProject] = []
    protocol_version = 'HTTP/1.1'

    def do_GET(self) -> None:
        self.handle_request('GET')

    def do_POST(self) -> None:
        self.handle_request('POST')

    def do_PUT(self) -> None:
        self.handle_request('PUT')

    def do_DELETE(self) -> None:
        self.handle_request('DELETE')

    def do_PATCH(self) -> None:
        self.handle_request('PATCH')

    def handle_request(self, method: str) -> None:
        body = self.read_body(method)
        if body is None:
            self.answer(413, 'тело запроса больше 1 МиБ'.encode('utf-8'), 'text/plain; charset=utf-8')
            return
        target = self.resolve(method, body)
        if target is None:
            self.answer(403, f'запрос не разрешён: {method} {self.path}'.encode('utf-8'), 'text/plain; charset=utf-8')
            return
        url, headers = target
        content_type = self.headers.get('Content-Type')
        if content_type:
            headers['Content-Type'] = content_type
        status, answer, answer_type = forward(method, url, headers, body)
        self.answer(status, answer, answer_type)

    def resolve(self, method: str, body: bytes) -> tuple[str, dict[str, str]] | None:
        if self.path.startswith('/redmine/') and self.tickethost is not None:
            path = self.path[len('/redmine'):]
            if allowed(method, path, REDMINE_ROUTES):
                return self.tickethost.url + path, {'X-Redmine-API-Key': self.tickethost.key}
        if self.path.startswith('/gitlab/') and self.projects:
            path = self.path[len('/gitlab'):]
            for project in self.projects:
                if allowed(method, path, project.routes()):
                    return project.url + path, {'PRIVATE-TOKEN': project.token}
            if allowed(method, path, GITLAB_SHARED):
                first = self.projects[0]
                return first.url + path, {'PRIVATE-TOKEN': first.token}
        if self.path.startswith('/github/') and self.github_projects:
            path = self.path[len('/github'):]
            for project in self.github_projects:
                if allowed(method, path, project.routes()):
                    return project.api + path, project.headers()
                if method == 'PATCH' and project.repository().match(path) and repository_settings_allowed(body):
                    return project.api + path, project.headers()
        return None

    def read_body(self, method: str) -> bytes | None:
        if method not in ('POST', 'PUT', 'PATCH'):
            return b''
        length = int(self.headers.get('Content-Length') or 0)
        if length > BODY_LIMIT:
            return None
        return self.rfile.read(length)

    def answer(self, status: int, body: bytes, content_type: str | None) -> None:
        self.send_response(status)
        if content_type:
            self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args) -> None:
        return

    def log_request(self, code: int | str = '-', size: int | str = '-') -> None:
        print(f'{self.command} {self.path} {code}', flush=True)


def forward(method: str, url: str, headers: dict[str, str], body: bytes) -> tuple[int, bytes, str | None]:
    call = urllib.request.Request(url, data=body if body else None, headers=headers, method=method)
    try:
        with urllib.request.urlopen(call, timeout=TIMEOUT) as response:
            return response.status, response.read(), response.headers.get('Content-Type')
    except urllib.error.HTTPError as error:
        return error.code, error.read(), error.headers.get('Content-Type')
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, 'reason', error)
        print(f'{method} {url} отказ: {reason}', flush=True)
        return 502, f'сервис недоступен: {reason}'.encode('utf-8'), 'text/plain; charset=utf-8'


def main() -> int:
    Broker.tickethost, Broker.projects, Broker.github_projects = load_services()
    if Broker.tickethost is None and not Broker.projects and not Broker.github_projects:
        print(f'ключей нет: {CREDENTIALS_DIR}/*.env без TICKETHOST_URL или CODEHOST_URL', flush=True)
        return 1
    print(f'посредник слушает {LISTEN[0]}:{LISTEN[1]}, проектов: {len(Broker.projects)}, '
          f'проектов GitHub: {len(Broker.github_projects)}, '
          f'сервис тикетов: {"есть" if Broker.tickethost else "нет"}', flush=True)
    ThreadingHTTPServer(LISTEN, Broker).serve_forever()
    return 0


if __name__ == '__main__':
    sys.exit(main())
