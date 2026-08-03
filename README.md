# OpenClaw Easy Setup

Windows 초보자가 OpenClaw를 안전하게 설치하고, 중단되더라도 이어서 진행하며, 모델과 메신저를 안전한 기본값으로 설정할 수 있도록 돕는 한국어 우선 설치 도우미입니다.

> 현재 상태: **한국어 Windows GUI 0.4**입니다. 실제 변경에는 계획 확인과 명시적인 동의가 필요합니다. 쉬운 설정에서 `적용`하기 전까지 PC의 OpenClaw 설정과 자격 증명은 바뀌지 않습니다. 이 프로젝트는 OpenClaw 공식 프로젝트가 아닙니다.

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
- OpenAI·Anthropic·Google 모델 제공자와 검토된 모델 선택
- 공식 `@openclaw/slack@2026.7.1` 플러그인의 고정 버전·npm 무결성 설치와 실행 시 재검증
- Slack 우선, Telegram·Discord 선택 연결과 DM 페어링·그룹 차단 기본값
- Windows Credential Manager와 네이티브 SecretRef resolver를 이용한 비밀정보 저장
- 공식 설정 스키마, dry-run, 설정 차이, 계획 지문을 확인한 뒤에만 적용하는 쉬운 설정 마법사
- 로컬 loopback Gateway, 256-bit 인증 토큰, messaging 권한과 명시적 고위험 도구 차단
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

## 이미 OpenClaw가 설치된 PC에서 시험하기

현재 설치를 건드리지 않고 화면과 계획만 확인하려면 `Diagnose`, `Plan`, `Install -Apply -WhatIf` 또는 두 GUI의 `-SmokeTest`를 사용할 수 있습니다. 실제 신규 설치를 시험하려면 Windows Sandbox 실행기를 사용하세요.

```powershell
./Start-OpenClawEasySetup.Sandbox.ps1 -Mode Gui
./Start-OpenClawEasySetup.Sandbox.ps1 -Mode InstallSmoke
```

`Gui`는 새 Windows 화면에서 직접 눌러보는 모드이고, `InstallSmoke`는 온보딩과 토큰 입력 없이 본체·Slack 플러그인 설치를 자동 검사하는 모드입니다. 실행에 필요한 고정 파일만 별도 staging 폴더로 복사해 읽기 전용으로 연결하고 `.git`, 문서, 로컬 비밀 파일과 나머지 작업 폴더는 노출하지 않습니다. 실행별 결과 폴더에는 정제된 `result.json`만 기록합니다. Sandbox 창을 닫으면 내부 설치와 자격 증명은 모두 삭제됩니다. Windows Sandbox 기능은 자동으로 활성화하지 않습니다.

기능 활성화 방법, 기존 설치의 공식 `--profile` 격리 시험, 결과 해석과 안전 경계는 [Windows Sandbox E2E 안내](docs/windows-sandbox-e2e.md)를 참고하세요.

## 쉬운 설정 마법사

메인 화면에서 `OpenClaw 설정`을 선택하면 0.4 설정 마법사가 열립니다.

1. OpenAI, Anthropic 또는 Google과 사용할 모델을 선택합니다.
2. 모델 API 키를 입력하고, 필요하면 가장 위의 Slack 또는 Telegram·Discord를 선택합니다. Slack은 먼저 [고정 커밋의 공식 Socket Mode manifest 절차](https://github.com/openclaw/openclaw/blob/2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4/docs/channels/slack.md)로 앱을 만들고 워크스페이스에 설치해야 하며, Bot User OAuth Token과 `connections:write` App-Level Token 두 개가 필요합니다. 모든 비밀값 입력란은 일반 텍스트 상자가 아닌 Windows WPF `PasswordBox`입니다.
3. `변경 미리보기`를 눌러 비밀값이 제거된 설정 차이와 공식 OpenClaw dry-run 결과를 확인합니다.
4. 내용을 확인한 뒤 기본적으로 꺼져 있는 적용 승인을 직접 선택하고 `설정 적용`을 누릅니다.

설치 단계는 OpenClaw 본체와 같은 `2026.7.1` 버전의 공식 Slack 플러그인을 정확한 npm integrity·shasum에 고정해 준비합니다. 이미 다른 출처나 버전의 `slack` 플러그인이 있으면 덮어쓰지 않고 중단합니다. 마법사는 Gateway용 256-bit 토큰을 자동 생성합니다. API 키와 채널 토큰은 현재 Windows 사용자의 Credential Manager에 실행별 고유 ID로 저장되고, OpenClaw 설정에는 평문 대신 네이티브 resolver를 가리키는 SecretRef만 기록됩니다. 선택한 공급자·채널과 Gateway 인증 등 Easy Setup 소유 경로는 공식 `--replace-path`로 정확히 교체해 이전 사용자 지정 API 주소나 헤더가 새 키를 받지 못하게 하고, 선택하지 않은 채널과 나머지 설정은 유지합니다. 적용 후에는 Slack 플러그인 출처, 승인 패치의 설정 해시 연속성·유효성·안전 불변 조건을 먼저 확인한 뒤만 Gateway를 설치·재시작하고, SecretRef resolver, 보안 감사, 모델·채널 상태와 Gateway RPC를 검사합니다. 첫 자격 증명 쓰기 전부터 전용 복구 기록을 남겨 중단·부분 적용을 다음 실행에서 감지하며, 새 적용 대신 안전한 정리 또는 사후 검사 재실행을 안내합니다. 중단된 모델·채널 자격 증명 교체는 별도 승인 뒤 기록에 묶인 전체 세트를 모두 다시 입력해 같은 ID에 완전히 다시 쓰어야 하며 Gateway token은 그대로 유지합니다. 설정 해시가 달라진 복구는 현재 파일을 그대로 신뢰하지 않고, 복구 기록의 OpenClaw 버전·스키마·활성 설정 경로를 재확인한 후 별도 승인 아래 Easy Setup 소유 경로만 기록에 묶인 패치로 복원합니다.

```text
Gateway        local + loopback + token, Tailscale/terminal 끔
도구           messaging 프로필 + runtime/fs/automation/ui/nodes/plugins/elevated 차단
Slack          Socket Mode + DM pairing + 채널/그룹 DM/명령/configWrites 차단
Telegram       DM pairing + 그룹 disabled + configWrites false
Discord        DM pairing + 서버 그룹 disabled + configWrites false
세션           채널과 상대별 DM 세션 분리
```

현재 구현 범위와 자격 증명 보안 경계, 실패 후 확인 사항은 [쉬운 설정 안내](docs/easy-setup.md)를 참고하세요.

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

설치 후 공식 대화형 온보딩과 상태 확인만 다시 실행할 수도 있습니다.

```powershell
./OpenClawEasySetup.ps1 -Action Configure -Apply
./OpenClawEasySetup.ps1 -Action Verify
```

CLI에서 한국어 쉬운 설정 마법사만 바로 열려면 다음 명령을 사용하세요. 이 우회는 현재 프로세스에만 적용되고, 마법사 안의 별도 승인 전에는 시스템을 변경하지 않습니다.

```powershell
powershell.exe -NoProfile -Sta -ExecutionPolicy Bypass -File .\OpenClawEasySetup.Settings.Gui.ps1
```

## 상태와 로그

기본 상태 폴더는 `%LOCALAPPDATA%\OpenClawEasySetup`입니다. 이곳에 재개용 체크포인트, 설치 무결성 영수증, 실제 설치·설정 실행 로그가 저장됩니다.

- 로그는 구조화된 형식으로 기록되며 알려진 개인정보·토큰·비밀값을 제거합니다.
- 명령줄 인수나 로그에 API 키와 토큰을 기록하지 않습니다.
- 체크포인트에는 설치 단계와 결과만 저장하고 인증정보는 저장하지 않습니다.
- 설치 무결성 영수증은 전체 패키지 콘텐츠 트리 SHA-256을 보존합니다. 이후에는 파일 메타데이터 트리와 명령 shim·진입점·`package.json` 콘텐츠 해시를 먼저 검사하고, 메타데이터가 달라진 경우에만 전체 콘텐츠 해시로 재검증합니다.
- 로그와 진단 번들은 어디에도 자동 전송되지 않습니다.
- 설정 마법사가 받은 비밀값은 로그·계획·설정 패치·명령줄 인수에 넣지 않습니다. 적용 후 입력 상자와 임시 `SecureString` 참조를 정리합니다.

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
- 공식 Slack 플러그인의 정확한 패키지·버전·npm integrity·shasum도 같은 파일에 고정하고 설치·검증합니다.
- 리디렉션이 발생해도 매 단계의 프로토콜과 호스트를 다시 검사합니다.
- 내려받은 스크립트는 크기·문법·SHA-256과 dry-run을 확인한 뒤에만 실행합니다.
- 재개할 때도 저장된 결과를 맹신하지 않고 현재 설치 상태와 보안 조건을 다시 확인합니다.
- 같은 목표 버전이 이미 있어도 유효한 무결성 영수증이 없으면 기존 패키지 코드를 실행하지 않습니다. npm 수명주기 스크립트를 끄고 해당 패키지만 제거한 뒤 고정 버전으로 다시 설치합니다.
- 관리자 권한을 자동 요청하지 않습니다.
- GUI 전체를 관리자 권한으로 실행하지 않습니다. 필요한 Git·Node.js 준비 단계에서만 WinGet 설치 프로그램이 Windows 권한 확인을 표시할 수 있습니다.
- GUI가 보여준 설치 계획과 실행 직전 계획의 SHA-256 지문이 다르면 설치를 차단합니다.
- GUI의 설치 취소는 개인 상태 폴더 안의 검증된 신호 파일을 사용하며 외부 프로세스를 강제로 종료하지 않습니다.
- 외부 공개, 공개 DM, 광범위한 도구 권한을 기본값으로 활성화하지 않습니다.
- 쉬운 설정은 OpenClaw `v2026.7.1`의 공식 `config schema`와 `config patch --stdin --dry-run --json` 계약을 사용합니다.
- 미리보기 뒤 공식 스키마나 기존 설정 파일이 바뀌면 SHA-256 freshness 검사가 적용을 중단하고 새 미리보기를 요구합니다.
- Credential Manager는 현재 Windows 사용자 계정의 평문 설정 노출을 줄이지만, 같은 사용자 권한으로 실행되는 악성 프로세스와의 격리 경계는 아닙니다.

자세한 내용은 [보안 정책](SECURITY.md)과 [아키텍처](docs/architecture.md)를 참고하세요.

## 공식 기준

2026-08-03에 다음 공식 자료를 검토해 요구사항을 기록했습니다.

- [OpenClaw 공식 저장소](https://github.com/openclaw/openclaw)
- [공식 설치 문서](https://docs.openclaw.ai/install)
- [Windows 문서](https://docs.openclaw.ai/platforms/windows)
- [보안 문서](https://docs.openclaw.ai/gateway/security)
- [설정 CLI 문서](https://docs.openclaw.ai/cli/config)
- [SecretRef 문서](https://docs.openclaw.ai/gateway/secrets)
- [고정 커밋의 Slack 설정 문서](https://github.com/openclaw/openclaw/blob/2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4/docs/channels/slack.md)

현재 공식 요구사항은 Node.js 26 권장, Node.js 22.22.3+, 24.15+ 또는 25.9+ 지원입니다. 공식 Windows 설치 후 `openclaw onboard --install-daemon`으로 온보딩할 수 있습니다. 이 도우미는 비밀정보를 평문으로 남길 가능성을 줄이기 위해 온보딩을 `--secret-input-mode ref`와 함께 시작합니다. 요구사항은 바뀔 수 있으므로 릴리스 전마다 다시 검토합니다.

## 프로젝트 구조

```text
Start-OpenClawEasySetup.cmd 초보자용 GUI 실행 파일
OpenClawEasySetup.Gui.ps1   한국어 WPF GUI
OpenClawEasySetup.Settings.Gui.ps1 쉬운 설정 WPF 마법사
OpenClawEasySetup.ps1       CLI 및 GUI 작업 프로세스 진입점
ui/                         시스템 색상 기반 메인·설정 WPF 화면
src/                        GUI 어댑터, 설치·설정 엔진, Credential Manager resolver
config/                     검토된 공식 출처와 런타임 요구사항
locales/                    한국어 메시지
tests/                      외부 의존성 없는 테스트
docs/                       설계 결정과 로드맵
.github/workflows/          Windows PowerShell 5.1/7 CI
```

## 다음 단계

다음 구현 목표는 코드 서명된 `.exe` 또는 MSIX, SBOM, 재현 가능한 빌드와 Windows 실기기 테스트를 포함하는 **1.0 배포**입니다. 자세한 범위는 [로드맵](docs/roadmap.md)에 정리합니다.
