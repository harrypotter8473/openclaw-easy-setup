# OpenClaw Easy Setup

Windows 초보자가 OpenClaw를 안전하게 설치하고 설정하도록 돕는 한국어 우선 설치 도우미입니다.

> 현재 상태: **초기 PowerShell MVP**입니다. 실행만으로 설치하지 않으며, 실제 변경에는 `-Apply`와 별도 확인이 필요합니다. 이 프로젝트는 OpenClaw 공식 프로젝트가 아닙니다.

## 지금 가능한 것

- PC 환경을 변경하지 않는 사전 진단
- 설치 전에 모든 변경 단계를 보여주는 계획 화면
- 공식 HTTPS 설치 스크립트만 허용하는 다운로드 정책
- 특정 OpenClaw 릴리스·커밋·설치 스크립트 SHA-256 고정
- Node.js가 없거나 지원되지 않으면 WinGet의 공식 패키지 ID·소스·버전을 고정해 Node 26 준비
- 다운로드 크기·PowerShell 문법·SHA-256 불일치 시 실행 차단
- 고정 설치 스크립트의 `-DryRun` 성공 후에만 실제 설치 허용
- 공식 온보딩, `doctor`, 보안 감사, Gateway 상태 검증 연결
- PowerShell 5.1 및 PowerShell 7 자동 테스트

## 빠른 시작

저장소를 내려받은 뒤 PowerShell에서 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
./OpenClawEasySetup.ps1 -Action Diagnose
./OpenClawEasySetup.ps1 -Action Plan
```

설치 명령도 기본값은 미리보기입니다.

```powershell
./OpenClawEasySetup.ps1 -Action Install
```

실제 설치에는 변경 의사를 명확히 표시해야 합니다.

```powershell
./OpenClawEasySetup.ps1 -Action Install -Apply
```

현재 MVP는 검토된 OpenClaw `v2026.7.1`과 해당 커밋의 설치 스크립트 SHA-256만 실행합니다. Node.js와 npm이 없거나 지원되지 않으면 WinGet의 `OpenJS.NodeJS` 패키지, `winget` 소스, Node.js `26.5.1`을 정확히 지정합니다. WinGet 매니페스트가 기록한 설치 파일 SHA-256도 프로젝트 설정에 함께 남겨 변경을 검토할 수 있게 합니다.

설치 후 설정과 검증만 다시 실행할 수도 있습니다.

```powershell
./OpenClawEasySetup.ps1 -Action Configure -Apply
./OpenClawEasySetup.ps1 -Action Verify
```

## 안전 원칙

- API 키와 토큰은 명령 인수, 저장소, 로그에 기록하지 않습니다.
- 설치 버전, 커밋, 주소, 최대 크기, SHA-256은 [`config/openclaw-source.json`](config/openclaw-source.json)에 함께 고정합니다.
- 리디렉션이 발생해도 매 단계의 프로토콜과 호스트를 다시 검사합니다.
- 내려받은 스크립트는 고유한 임시 파일에 저장하고 기본적으로 실행 후 삭제합니다.
- 관리자 권한을 자동 요청하지 않습니다.
- 설치와 온보딩은 읽기 전용 진단 및 계획과 분리합니다.
- 외부 공개, 공개 DM, 광범위한 도구 권한을 기본값으로 활성화하지 않습니다.

자세한 내용은 [보안 정책](SECURITY.md)과 [아키텍처](docs/architecture.md)를 참고하세요.

## 공식 기준

2026-08-02에 다음 공식 자료를 검토해 초기 요구사항을 기록했습니다.

- [OpenClaw 공식 저장소](https://github.com/openclaw/openclaw)
- [공식 설치 문서](https://docs.openclaw.ai/install)
- [Windows 문서](https://docs.openclaw.ai/platforms/windows)
- [보안 문서](https://docs.openclaw.ai/gateway/security)

현재 공식 요구사항은 Node.js 26 권장, Node.js 22.22.3+, 24.15+ 또는 25.9+ 지원입니다. 공식 Windows 설치 후 `openclaw onboard --install-daemon`으로 온보딩할 수 있습니다. 이 도우미는 비밀정보를 평문으로 남길 가능성을 줄이기 위해 온보딩을 `--secret-input-mode ref`와 함께 시작합니다. 요구사항은 바뀔 수 있으므로 릴리스 전마다 다시 검토합니다.

## 프로젝트 구조

```text
OpenClawEasySetup.ps1       사용자 진입점
src/                        진단·다운로드·설치 엔진
config/                     검토된 공식 출처와 런타임 요구사항
locales/                    한국어 메시지
tests/                      외부 의존성 없는 테스트
docs/                       설계 결정과 로드맵
.github/workflows/          Windows PowerShell 5.1/7 CI
```

## 다음 단계

1. 오류 코드와 비밀정보 제거 로그
2. 중단 후 이어하기 및 복구 체크포인트
3. 안전한 기본 설정 생성과 스키마 검증
4. Windows 데스크톱 GUI
5. 서명된 `.exe`/MSIX 릴리스와 자동 업데이트

자세한 범위는 [로드맵](docs/roadmap.md)에 정리합니다.
