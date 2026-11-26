// fitlog 서버 스모크·가벼운 부하 테스트 (k6). 실행:
//   k6 run -e BASE_URL=https://fit.example.com -e ACCESS_TOKEN=<액세스 토큰> server/deploy/load/k6-smoke.js
// ACCESS_TOKEN 이 없으면 인증이 필요 없는 경로(health, privacy)만 친다.
// 호출 제한(기본 사용자당 분당 300)에 걸리면 429 가 나오므로, 부하를 올리려면 RATE_LIMIT_* 를 임시로 키운다.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const TOKEN = __ENV.ACCESS_TOKEN || '';

export const options = {
  stages: [
    { duration: '20s', target: 5 },
    { duration: '40s', target: 5 },
    { duration: '10s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<500'],
  },
};

export default function () {
  const health = http.get(`${BASE}/health/ready`);
  check(health, { 'ready 200': (r) => r.status === 200 });

  const privacy = http.get(`${BASE}/privacy`);
  check(privacy, { 'privacy 200': (r) => r.status === 200 });

  if (TOKEN) {
    const headers = { Authorization: `Bearer ${TOKEN}` };
    const me = http.get(`${BASE}/v1/me`, { headers });
    check(me, { 'me 200': (r) => r.status === 200 });
    const ex = http.get(`${BASE}/v1/exercises`, { headers });
    check(ex, { 'exercises 200': (r) => r.status === 200 });
    const sessions = http.get(`${BASE}/v1/sessions?limit=20`, { headers });
    check(sessions, { 'sessions 200': (r) => r.status === 200 });
  }
  sleep(1);
}
