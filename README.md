# OpenClaw Easy Setup

Windows 초보자가 OpenClaw를 안전하게 설치하고, 중단되더라도 이어서 진행할 수 있도록 돕는 한국어 우선 설치 도우미입니다.

> 현재 상태: **한국어 Windows GUI 0.3**입니다. 실제 변경에는 계획 확인과 명시적인 동의가 필요합니다. 이 프로젝트는 OpenClaw 공식 프로젝트가 아닙니다.

## 지금 가능한 것

- PC 환경을 변경하지 않는 사전 진단과 설치 계획 확인
- 공식 HTTPS 설치 스크립트와 고정된 릴리스·커밋·SHA-256 검증
- 필요한 경우 WinGet의 정확한 패키지·소스·버전으로 Git for Windows와 Node.js 준비
- 다운로드 크기·PowerShell 문법·무결성 불일치 시 실행 차단
- 단계별 체크포인트 저장과 중단된 설치 이어하기
- 안정적인 오류 코드와 개인정보·토큰을 제거한 구조화 로그
- 기존 OpenClaw 설치를 확인한 뒤 유지·업데이트·다운그레이드 차단 판단
- 인터넷 연결 없이 만들 수 있는 문제 해결용 진단 번들
- 공식 온보딩, `doctor`, 보안 감사, Gateway 상태 검증 연결
- 명령어 없이 실행할 수 있는 한국어 단계형 Windows GUI
- 설치 계획 지문 확인, 기본 거부 승인, 단계별 진행 표시와 안전한 취소
- 중단된 설치 자동 감지, 한 번 누르는 재개, 오류 코드·로그·진단 ZIP 안내
- Windows 시스템 색상, 키보드 탐색과 화면 읽기 도구용 접근성 정보
- PowerShell 5.1 및 PowerShell 7 자동 테스트

## 가장 쉬운 시작

저장소를 내려받은 뒤 **`Start-OpenClawEasySetup.cmd`를 두 번 클릭**하세요. 이 실행 파일은 Windows에 포함된 PowerShell을 일반 사용자 권한으로 열고 GUI만 시작합니다.

명령으로 열려면 PowerShell에서 다음을 실행합니다.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
./OpenClawEasySetup.Gui.ps1
```

GUI에서는 다음 작업을 선택할 수 있습니다.

```text
1. PC 확인
2. 설치 시작
3. 이전 설치 이어하기
4. OpenClaw 설정
5. 설치 상태 확인
6. 문제 해결 파일 만들기
```

`설치 시작`과 `이전 설치 이어하기`는 먼저 8단계 설치 계획을 보여줍니다. 동의 체크는 기본적으로 꺼져 있고 Enter 키의 기본 동작도 `아니요, 돌아가기`입니다. 설치 과정은 별도 PowerShell 프로세스에서 실행되므로 GUI 프로세스와 설치 환경이 섞이지 않습니다.

취소를 누르면 WinGet이나 설치 프로그램을 강제로 종료하지 않습니다. 현재 안전 단계가 끝난 뒤 멈추고 체크포인트를 남기므로, 다음 실행에서 `이전 설치 이어하기`로 계속할 수 있습니다.

`Start-OpenClawEasySetup.cmd`의 실행 정책 우회는 해당 PowerShell 프로세스에만 적용되며 Windows의 영구 실행 정책을 변경하지 않습니다.

## CLI로 실행하기

GUI 없이 기존 메뉴를 사용하려면 다음을 실행합니다.

```powershell
./OpenClawEasySetup.ps1
```

진단과 계획 확인은 PC를 변경하지 않습니다.

```powershell
./OpenClawEasySetup.ps1 -Action Diagnose
./OpenClawEasySetup.ps1 -Action Plan
```

설치 명령의 기본 동작도 미리보기입니다. 실제 설치에는 `-Apply`가 필요합니다.

```powershell
./OpenClawEasySetup.ps1 -Action Install
./OpenClawEasySetup.ps1 -Action Install -Apply
```

설치가 중단되었다면 완료된 단계를 확인한 뒤 안전한 지점부터 이어갑니다. 재개하더라도 PC 상태와 다운로드 무결성을 다시 검사하며, 실제 변경에는 다시 `-Apply`가 필요합니다.

```powershell
./OpenClawEasySetup.ps1 -Action Install -Resume
./OpenClawEasySetup.ps1 -Action Install -Resume -Apply
```

설치 후 설정과 상태 확인만 다시 실행할 수도 있습니다.

```powershell
./OpenClawEasySetup.ps1 -Action Configure -Apply
./OpenClawEasySetup.ps1 -Action Verify
```

## 상태와 로그

기본 상태 폴더는 `%LOCALAPPDATA%\OpenClawEasySetup`입니다. 이곳에 재개용 체크포인트, 설치 무결성 영수증, 실제 설치·설정 실행 로그가 저장됩니다.

- 로그는 구조화된 형식으로 기록되며 알려진 개인정보·토큰·비밀값을 제거합니다.
- 명령줄 인수나 로그에 API 키와 토큰을 기록하지 않습니다.
- 체크포인트에는 설치 단계와 결과만 저장하고 인증정보는 저장하지 않습니다.
- 설치 무결성 영수증은 OpenClaw 패키지 파일 트리와 명령 shim의 SHA-256을 기록하며, 이후 설정·검증 전에 다시 비교합니다.
- 로그와 진단 번들은 어디에도 자동 전송되지 않습니다.

상태 폴더를 별도로 지정하려면 모든 관련 실행에 같은 경로를 사용하세요.

```powershell
./OpenClawEasySetup.ps1 -Action Install -Apply -StateDirectory 'D:\OpenClawEasySetup-State'
./OpenClawEasySetup.ps1 -Action Install -Resume -Apply -StateDirectory 'D:\OpenClawEasySetup-State'
```

## 문제 해결 파일 만들기

설치가 실패했거나 도움을 요청해야 할 때 진단 ZIP을 만들 수 있습니다. 이 작업은 OpenClaw 설치·설정을 바꾸거나 파일을 자동 업로드하지 않으며, 지정한 로컬 위치에 ZIP만 만듭니다.

```powershell
./OpenClawEasySetup.ps1 -Action Bundle
./OpenClawEasySetup.ps1 -Action Bundle -DiagnosticOutputPath 'C:\Users\Public\OpenClaw-Easy-Setup-Diagnostics.zip'
```

번들에는 정제된 로그, 체크포인트, PC 준비 상태와 도구 버전 등 문제 해결에 필요한 정보만 포함됩니다. 생성 후 화면에 표시되는 경로를 확인한 뒤, 사용자가 직접 선택한 지원 채널에만 첨부하세요.

## 설치 안전 원칙

- 현재 검토된 OpenClaw `v2026.7.1`과 해당 커밋의 설치 스크립트 SHA-256만 실행합니다.
- 신뢰할 수 있는 Git for Windows가 없으면 WinGet의 `Git.Git` `2.55.0.3`을 정확히 지정합니다. 공식 설치 스크립트에는 이 서명된 Git만 노출해 별도의 고정되지 않은 Git 다운로드를 막습니다.
- Node.js와 npm이 없거나 지원되지 않으면 WinGet의 `OpenJS.NodeJS` 패키지, `winget` 소스, Node.js `26.5.1`을 정확히 지정합니다.
- 설치 버전, 커밋, 주소, 최대 크기, SHA-256은 [`config/openclaw-source.json`](config/openclaw-source.json)에 함께 고정합니다.
- 리디렉션이 발생해도 매 단계의 프로토콜과 호스트를 다시 검사합니다.
- 내려받은 스크립트는 크기·문법·SHA-256과 dry-run을 확인한 뒤에만 실행합니다.
- 재개할 때도 저장된 결과를 맹신하지 않고 현재 설치 상태와 보안 조건을 다시 확인합니다.
- 같은 목표 버전이 이미 있어도 유효한 무결성 영수증이 없으면 기존 패키지 코드를 실행하지 않습니다. npm 수명주기 스크립트를 끄고 해당 패키지만 제거한 뒤 고정 버전으로 다시 설치합니다.
- 관리자 권한을 자동 요청하지 않습니다.
- GUI 전체를 관리자 권한으로 실행하지 않습니다. 필요한 Git·Node.js 준비 단계에서만 WinGet 설치 프로그램이 Windows 권한 확인을 표시할 수 있습니다.
- GUI가 보여준 설치 계획과 실행 직전 계획의 SHA-256 지문이 다르면 설치를 차단합니다.
- GUI의 설치 취소는 개인 상태 폴더 안의 검증된 신호 파일을 사용하며 외부 프로세스를 강제로 종료하지 않습니다.
- 외부 공개, 공개 DM, 광범위한 도구 권한을 기본값으로 활성화하지 않습니다.

자세한 내용은 [보안 정책](SECURITY.md)과 [아키텍처](docs/architecture.md)를 참고하세요.

## 공식 기준

2026-08-02에 다음 공식 자료를 검토해 요구사항을 기록했습니다.

- [OpenClaw 공식 저장소](https://github.com/openclaw/openclaw)
- [공식 설치 문서](https://docs.openclaw.ai/install)
- [Windows 문서](https://docs.openclaw.ai/platforms/windows)
- [보안 문서](https://docs.openclaw.ai/gateway/security)

현재 공식 요구사항은 Node.js 26 권장, Node.js 22.22.3+, 24.15+ 또는 25.9+ 지원입니다. 공식 Windows 설치 후 `openclaw onboard --install-daemon`으로 온보딩할 수 있습니다. 이 도우미는 비밀정보를 평문으로 남길 가능성을 줄이기 위해 온보딩을 `--secret-input-mode ref`와 함께 시작합니다. 요구사항은 바뀔 수 있으므로 릴리스 전마다 다시 검토합니다.

## 프로젝트 구조

```text
Start-OpenClawEasySetup.cmd 초보자용 GUI 실행 파일
OpenClawEasySetup.Gui.ps1   한국어 WPF GUI
OpenClawEasySetup.ps1       CLI 및 GUI 작업 프로세스 진입점
ui/                         시스템 색상 기반 WPF 화면
src/                        GUI 어댑터와 진단·복구·다운로드·설치 엔진
config/                     검토된 공식 출처와 런타임 요구사항
locales/                    한국어 메시지
tests/                      외부 의존성 없는 테스트
docs/                       설계 결정과 로드맵
.github/workflows/          Windows PowerShell 5.1/7 CI
```

## 다음 단계

다음 구현 목표는 모델 제공자와 메신저 연결을 안전하게 안내하는 **쉬운 설정 마법사 0.4**입니다. 이후 서명된 `.exe` 또는 MSIX 배포를 준비합니다. 자세한 범위는 [로드맵](docs/roadmap.md)에 정리합니다.
