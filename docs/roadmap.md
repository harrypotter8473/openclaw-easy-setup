# Roadmap

## 0.1 — 안전한 CLI 엔진

- [x] Windows/PowerShell/CPU/디스크/Git/Node/OpenClaw 진단
- [x] 설치 계획 미리보기
- [x] HTTPS 호스트 및 리디렉션 허용 목록
- [x] 릴리스·커밋·SHA-256 고정 및 Authenticode 상태 확인
- [x] 설치 스크립트 크기·문법 검증과 dry-run
- [x] WinGet exact 패키지와 버전을 이용한 Node.js 자동 준비
- [x] 고정된 Git for Windows 준비와 공식 설치기의 비고정 Git 다운로드 차단
- [x] 명시적 설치 승인
- [x] 공식 온보딩 및 보안 검증 연결
- [x] PowerShell 5.1/7 CI

## 0.2 — 복구 가능한 설치

- [x] 안정적인 오류 코드와 사용자 행동 안내
- [x] 개인정보·토큰을 제거한 구조화 로그
- [x] 단계별 체크포인트와 `-Resume`
- [x] `-StateDirectory`를 통한 상태·로그 위치 지정
- [x] 기존 설치 업데이트·유지·다운그레이드 차단 판단
- [x] 설치 파일 트리 무결성 영수증과 실행 전 재검증
- [x] 자동 전송하지 않는 오프라인 진단 번들
- [x] `-DiagnosticOutputPath`를 통한 진단 ZIP 저장 위치 지정

## 0.3 — Windows GUI

- [x] PowerShell 명령을 몰라도 사용할 수 있는 한국어 단계별 화면
- [x] PC 확인·설치·재개·설정·검증 진행 표시
- [x] 설치 계획과 기본값 `N`인 변경 승인 화면
- [x] 중단된 설치 감지와 한 번 누르는 이어하기
- [x] 오류 코드·로그 위치·문제 해결 파일 생성 안내
- [x] 키보드 탐색, 화면 읽기 도구, 고대비 등 접근성 확인
- [x] GUI는 일반 권한으로 유지하고 필요한 WinGet 설치 단계만 Windows 권한 확인
- [x] 설치 취소와 복구 UX

## 0.4 — 쉬운 설정

- [x] 공식 `config schema`, `config validate`, `config patch --dry-run --json` 검증
- [x] 스키마·기존 설정 SHA-256 freshness 확인과 승인된 계획 지문
- [x] 로컬 loopback Gateway와 자동 생성 256-bit 인증 토큰
- [x] OpenAI·Anthropic·Google 모델 제공자 및 검토된 모델 선택
- [x] Windows Credential Manager와 네이티브 exec resolver를 통한 SecretRef 저장
- [x] Slack 우선, Telegram·Discord 채널별 PasswordBox 입력과 안전한 선택형 마법사
- [x] 공식 Slack 플러그인의 본체 동버전·npm 무결성 고정 설치와 runtime 출처 검증
- [x] DM 페어링, 그룹 차단, 채널 설정 쓰기 차단 기본값
- [x] messaging 프로필과 고위험 도구·elevated 명시적 차단
- [x] 비밀값이 제거된 설정 차이 미리보기와 기본 거부 적용 승인
- [x] 적용 후 설정·SecretRef·보안·모델·채널·Gateway 상태 검사

## 0.5 — 격리 설치 시험

- [x] 기존 설치를 변경하지 않는 CLI `-WhatIf`와 GUI smoke 경로
- [x] GitHub Actions 임시 Windows runner에서 수동 실행하는 토큰 없는 설치 E2E
- [x] 본체·Slack 플러그인의 버전·출처·무결성과 설치 영수증 검증
- [x] 원시 로그 대신 정제된 단계 상태와 오류 코드만 보존
- [x] Windows Sandbox 실행기는 호환 환경용 선택 경로로 유지하고 기본 합격 판정에서는 제외
- [ ] 전용 Hyper-V VM 체크포인트 기반 GUI 클릭·재부팅·복구·반복 E2E

## 1.0 — 배포

- [ ] 코드 서명된 `.exe` 또는 MSIX
- [ ] SBOM과 재현 가능한 빌드 정보
- [ ] 외부 플러그인 압축 해제 파일의 독립 콘텐츠 트리 영수증과 재검증
- [ ] 서명·해시 검증을 포함한 자동 업데이트
- [ ] Windows 10/11 설치·업데이트·삭제 테스트 매트릭스
- [ ] 실제 데스크톱에서 키보드 전용, NVDA, 고대비, 200% DPI 접근성 검증
