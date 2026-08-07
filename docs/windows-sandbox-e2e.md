# 기존 OpenClaw가 있는 PC에서 격리 시험하기

이미 OpenClaw가 설치된 PC에서는 `-StateDirectory`만 바꿔 실제 설치를 반복하면 안 됩니다. 이 값은 Easy Setup의 로그와 체크포인트를 분리하지만, npm 전역 패키지, 사용자 PATH, OpenClaw 설정, Windows Credential Manager 같은 설치 대상까지 격리하지는 않습니다.

시험 목적에 따라 다음 세 단계를 사용하세요.

## 1. 현재 PC에서 변경 없는 예행연습

다음 명령은 다운로드, 설치, OpenClaw 설정 쓰기 또는 Credential Manager 쓰기를 하지 않습니다.

```powershell
./OpenClawEasySetup.ps1 -Action Diagnose
./OpenClawEasySetup.ps1 -Action Plan
./OpenClawEasySetup.ps1 -Action Install -Apply -WhatIf
./OpenClawEasySetup.Gui.ps1 -SmokeTest
./OpenClawEasySetup.Settings.Gui.ps1 -SmokeTest
```

이 단계는 현재 설치와의 충돌, 설치 계획, GUI 로딩을 확인하는 데 적합합니다. 완전 신규 PC의 Git·Node.js·npm·OpenClaw 설치 분기는 검증하지 않습니다.

## 2. 기존 OpenClaw의 격리 프로필

OpenClaw `2026.7.1`은 공식 `--profile` 전역 옵션으로 설정과 상태를 별도 폴더에 분리합니다. 기존 Gateway와 겹치지 않는 포트를 사용하고 서비스를 설치하지 않은 채 포그라운드에서 실행하세요.

```powershell
openclaw --profile easysetup-test setup
openclaw --profile easysetup-test gateway --port 19789
```

이 방법은 이미 설치된 OpenClaw의 기능을 빠르게 시험하는 용도입니다. npm 전역 설치와 Windows PATH 같은 설치기 변경은 격리하지 않으며, `~/.openclaw-easysetup-test`의 시험 상태는 자동 삭제되지 않습니다. 공식 경로 규칙은 [고정 버전 환경 변수 문서](https://github.com/openclaw/openclaw/blob/2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4/docs/help/environment.md)와 [다중 Gateway 문서](https://github.com/openclaw/openclaw/blob/2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4/docs/gateway/multiple-gateways.md)를 기준으로 합니다.

## 3. 기본 자동 E2E: GitHub Actions 임시 Windows runner

신규 설치 자동 검사의 기본 경로는 GitHub가 실행별로 제공하고 작업 뒤 폐기하는 임시 Windows runner입니다.

워크플로 파일이 포함된 PR을 검토해 기본 브랜치에 병합한 뒤 실행합니다.
1. 저장소의 `Actions` 탭을 엽니다.
2. `Windows Install E2E`를 선택합니다.
3. `Run workflow`를 눌러 수동 실행하고 Summary의 정제된 결과를 확인합니다.

설치와 검증은 GitHub의 임시 머신에서만 실행됩니다. 사용자의 PC에서 Windows 기능·드라이버·가상화 설정을 바꾸거나 재부팅하지 않으며 API 키, 메신저 토큰 또는 저장소 secret을 전달하지 않습니다. 자세한 검사 범위와 결과 해석은 [GitHub 임시 Windows E2E 안내](github-hosted-windows-e2e.md)를 참고하세요.

## 4. GUI 클릭 시험: 전용 Hyper-V VM

버튼 클릭, 권한 확인 창, 재부팅, 설치 재개와 복구를 포함하는 GUI 시험은 깨끗한 Windows 체크포인트가 있는 전용 Hyper-V VM에서만 진행합니다. 운영용 API 키나 Slack 토큰을 사용하지 말고 시험용 자격 증명을 사용하세요. 이 프로젝트는 Hyper-V를 자동으로 활성화하거나 VM을 만들지 않습니다.

## 5. Windows Sandbox: 선택적 호환 경로

Windows Sandbox는 기본 자동 E2E 또는 GUI 합격 판정 경로가 아닙니다. Sandbox가 이미 안정적으로 동작하는 별도 개발 PC에서만 선택적으로 사용할 수 있습니다.

> 연결 경고가 다시 나타나거나 `다시 연결`이 반복되면 버튼을 계속 누르지 말고 Sandbox 창을 닫은 뒤 즉시 시험을 중단하세요. 같은 PC에서 반복 실행하거나 복구를 시도하지 말고 GitHub Actions 또는 전용 Hyper-V VM을 사용하세요.

이 프로젝트는 Windows Sandbox 기능을 켜거나 복구하지 않으며 PC를 재부팅하지 않습니다. 기능이 꺼져 있거나 연결이 불안정하면 활성화를 시도하지 말고 GitHub Actions를 사용하세요.

### 이미 안정적인 별도 PC에서 화면 시험

```powershell
./Start-OpenClawEasySetup.Sandbox.ps1 -Mode Gui
```

실행기는 필요한 16개 런타임 파일만 호스트의 실행별 staging 폴더에 복사하고 SHA-256을 다시 확인한 뒤, 이 폴더만 `C:\OCES-Source`에 읽기 전용으로 연결합니다. `.git`, 문서, 로컬 환경 파일과 나머지 작업 폴더는 Sandbox에 노출하지 않습니다. 코드는 다시 Sandbox 내부의 쓰기 가능한 일회용 폴더로 복사된 뒤 GUI가 시작됩니다.

### 토큰 없이 실제 설치 단계 자동 검사하기

```powershell
./Start-OpenClawEasySetup.Sandbox.ps1 -Mode InstallSmoke
```

이 모드는 온보딩을 건너뛰고 다음 항목만 확인합니다.

- 깨끗한 환경에 OpenClaw가 사전 설치되어 있지 않은지
- 고정 버전 설치가 종료 코드 0으로 끝나는지
- 설치 체크포인트의 `install` 단계가 성공했는지
- 본체 provenance 영수증과 실제 패키지 내용이 다시 검증되는지
- 설치된 본체 버전이 고정 목표와 일치하는지
- 별도의 비실행 snapshot으로 Slack 플러그인 설치·출처·버전·npm 무결성이 다시 검증되는지

원시 표준 출력·오류와 Sandbox 내부 로그는 호스트로 복사하지 않습니다. 실행별 전용 결과 폴더에 단계 ID·상태, 고정 버전, 안정적인 오류 코드만 포함한 `result.json`이 남고, 정확한 호스트 경로가 시작 콘솔에 표시됩니다.

호스트의 `%TEMP%\OpenClawEasySetup-E2E`에는 결과 폴더 외에도 비밀값이 없는 실행별 staging 복사본과 `.wsb` 설정 파일이 남을 수 있습니다. 실행 중인 Sandbox를 모두 닫은 뒤 파일 탐색기에서 이 전용 임시 폴더를 확인하고 삭제할 수 있습니다. 운영 토큰이나 원시 설치 로그는 이곳에 기록하지 않습니다.

### 안전 경계

- 전체 호스트 저장소 대신 명시적 파일 허용 목록으로 만든 staging 폴더만 매핑하며, Sandbox 안에서 실제 쓰기 거부도 다시 검사합니다.
- 쓰기 가능한 매핑은 실행별 새 빈 결과 폴더 하나뿐입니다.
- vGPU, 마이크, 카메라, 프린터와 클립보드 공유는 기본적으로 꺼집니다.
- 네트워크는 공식 설치 파일과 npm 패키지를 받기 위해 켜집니다.
- `InstallSmoke`는 온보딩을 실행하지 않고 API 키나 메신저 토큰을 받지 않습니다.
- `Gui`에서도 운영용 API 키나 운영 Slack 토큰 대신 별도 시험용 워크스페이스와 자격 증명을 사용하세요.
- 꼭 필요한 경우에만 `-EnableClipboard`를 명시하세요. 이 옵션은 호스트와 Sandbox 사이의 클립보드 공유 경계를 엽니다.
- Windows Sandbox 이미지에 WinGet/App Installer가 없다면 신규 전제 조건 준비 단계가 실패할 수 있습니다. 이 실패도 결과 JSON에 기록됩니다. 재부팅·복구·반복 설치까지 장기 시험하려면 깨끗한 체크포인트가 있는 전용 Hyper-V VM을 사용하세요.

Microsoft의 현재 동작과 보안 경계는 [Windows Sandbox 개요](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/)와 [`.wsb` 설정 문서](https://learn.microsoft.com/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)를 기준으로 합니다.
