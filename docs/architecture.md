# Architecture

## 목표

OpenClaw Easy Setup은 초보자용 화면과 실제 시스템 변경 코드를 분리합니다. 한국어 Windows GUI는 복구 가능한 PowerShell CLI를 별도 작업 프로세스로 재사용합니다.

```text
한국어 WPF GUI / CLI
        |
        v
계획 지문·기본 거부 승인·별도 작업 프로세스
        |
        +-- 설치 ------------------------------+
        |                                     |
        |  진단·계획 → 체크포인트 → 승인      |
        |       → 고정 의존성·설치 → 검증      |
        |                                     |
        +-- 쉬운 설정 -------------------------+
              제공자·모델·채널 선택
                 → live schema/config hash
                 → redacted patch + dry-run
                 → 별도 승인 + freshness 검사
                 → Credential Manager + SecretRef
                 → patch + Gateway + 감사

오프라인 진단 번들 (자동 전송 없음)
```

## 구성요소

- `OpenClawEasySetup.ps1`: CLI 메뉴와 GUI 작업 프로세스의 공용 진입점
- `Start-OpenClawEasySetup.cmd`: 영구 정책 변경 없이 GUI를 여는 더블클릭 실행 파일
- `OpenClawEasySetup.Gui.ps1`: WPF 화면, 승인·진행·결과·복구 UX와 작업 프로세스 수명 주기
- `OpenClawEasySetup.Settings.Gui.ps1`: 제공자·모델·채널 선택, PasswordBox 입력, 미리보기와 별도 적용 승인을 담당하는 설정 마법사
- `ui/MainWindow.xaml`: 시스템 색상과 DPI 대응 레이아웃
- `ui/SettingsWindow.xaml`: 설정 마법사의 접근 가능한 WPF 레이아웃
- `src/OpenClawEasySetup.Gui.psm1`: 읽기 전용 화면 모델, 인수 인코딩, 작업 프로세스·결과 어댑터
- `src/OpenClawEasySetup.psm1`: 상태 진단, 출처 검증, 복구 가능한 설치, 온보딩, 검증
- `src/PackageIntegrity/OpenClawEasySetup.PackageTreeHasher.cs`: 전체 패키지 콘텐츠 해시, 결정적 메타데이터 트리 해시와 핵심 파일 경쟁 검사
- `src/OpenClawEasySetup.Settings.psm1`: live schema/config 검증, 안전한 merge patch, 계획 지문, 공식 dry-run·적용·사후 검사
- `src/OpenClawEasySetup.CredentialManager.psm1`: 실행별 자격 증명 ID, Windows Credential Manager 호출, resolver 빌드·경로·ACL 검증
- `src/CredentialResolver/OpenClawEasySetup.SecretResolver.cs`: OpenClaw exec SecretRef 프로토콜 v1과 Credential Manager 사이의 네이티브 resolver
- `config/openclaw-source.json`: 코드와 분리된 공식 출처·요구사항
- `locales/ko-KR.json`: Windows PowerShell 5.1에서도 안전하게 읽는 UTF-8 한국어 메시지
- `tests/Run-Tests.ps1`: Pester 설치 없이 실행되는 결정적 단위·스모크 테스트
- `tests/Run-GuiTests.ps1`: 화면을 표시하지 않고 기본 거부·접근성·무변경·재개·취소 경계를 검증하는 STA 테스트
- `tests/Run-SettingsTests.ps1`: 설정 패치, SecretRef, 안전 기본값, 계획 freshness와 resolver 계약을 검증하는 테스트
- `tests/Run-CredentialResolverTests.ps1`: 임시 경로에서 네이티브 resolver를 빌드해 프로토콜 제한, 잘못된 입력 거부와 무자격 증명 경로를 검증하는 테스트

## 설계 결정

### PowerShell-first

별도 앱 런타임을 설치하기 전에 Windows 기본 환경에서 진단할 수 있어야 합니다. GUI도 Windows에 포함된 WPF와 Windows PowerShell 5.1만 사용하며, 검증된 CLI 엔진을 다시 구현하지 않고 별도 작업 프로세스로 호출합니다.

### GUI와 설치 프로세스 분리

GUI는 일반 사용자 권한과 STA 스레드에서 실행합니다. 설치·진단·검증은 OS가 제공하는 실제 시스템 디렉터리에서 Windows PowerShell 경로를 만들고, 파일이 재분석 지점이 아니며 Authenticode 서명자가 Microsoft Corporation인지 확인한 뒤 별도 프로세스에서 실행합니다. Windows PowerShell 진입점은 상위 프로세스의 모듈 검색 경로를 버리고 해당 시스템 PowerShell의 기본 모듈 디렉터리만 사용합니다. GUI는 WinGet, npm, 다운로드 함수를 직접 호출하지 않으며 전체 앱에 `runas`를 사용하지 않습니다. 공식 온보딩만 사용자가 입력할 수 있는 별도 콘솔로 열고, 설치 본체는 `-SkipOnboarding`으로 비대화형 실행합니다.

### 계획 승인과 TOCTOU 방어

설치·재개 화면의 동의는 기본적으로 꺼져 있고 시작 버튼도 비활성화되어 있습니다. Enter와 취소 동작은 설치를 시작하지 않습니다. 사용자가 본 8단계 계획은 출처 설정 SHA-256과 변경 의미를 묶은 계획 지문으로 기록되며, CLI 작업 프로세스가 실행 직전에 다시 계산한 지문과 일치할 때만 `-Apply`를 수행합니다.

### 협력적 취소

GUI는 실행 중인 WinGet·npm·설치 프로세스를 강제로 종료하지 않습니다. 개인 ACL이 적용된 상태 폴더의 무작위 이름 신호 파일만 만들고, 엔진은 체크포인트 단계 사이의 안전 경계에서 이 파일을 검증합니다. 취소하면 `OCES-CANCELLED-001`/exit 61로 끝나며 실행 중인 단계가 없는 재개 가능한 체크포인트를 남깁니다.

### 접근성

화면은 Windows `SystemColors` 동적 리소스를 사용해 고대비 설정을 따르고, 스크롤 가능한 DPI 대응 레이아웃과 명시적인 탭 순서를 가집니다. 상태는 색만으로 표현하지 않고 텍스트와 기호를 함께 표시합니다. 모든 대화형 요소에는 한국어 자동화 이름과 도움말이 설정됩니다.

### 읽기와 쓰기의 분리

`Diagnose`, `Plan`, 기본 `Install`은 시스템 설치 상태를 바꾸지 않습니다. `Bundle`은 OpenClaw 설치·설정을 바꾸지 않고 로컬 진단 ZIP만 만듭니다. 실제 설치와 설정에는 `-Apply`와 명시적 확인이 필요합니다. 메뉴의 설치 시작도 계획을 먼저 보여주고 기본값이 `N`인 질문으로 승인 경계를 만듭니다.

### 복구 가능한 실행 상태

기본 상태 루트는 `%LOCALAPPDATA%\OpenClawEasySetup`입니다. 실행별 체크포인트는 단계의 시작·완료·실패를 기록하고, `-Resume`은 최신 미완료 기록을 찾아 현재 PC 상태를 다시 검사한 뒤 안전한 지점부터 계속합니다. 설치 단계는 현재 버전뿐 아니라 이 도우미가 기록한 패키지 트리·명령 shim 무결성 영수증까지 일치할 때만 건너뜁니다. 최신 실행이 완료되었다면 더 오래된 실패 기록을 되살리지 않습니다. `-StateDirectory`로 상태 루트를 바꿀 때는 설치·재개·설정·검증에 같은 경로를 사용합니다.

영수증 생성은 패키지 전체 콘텐츠 트리 SHA-256과 결정적 메타데이터 트리 SHA-256을 함께 기록합니다. 일반 검증은 상대 경로·크기·생성/수정 UTC 시각·속성으로 구성한 메타데이터 트리와 명령 shim·진입점·`package.json`의 콘텐츠 해시를 먼저 확인하고, 메타데이터가 달라졌을 때만 전체 콘텐츠 트리 해시로 되돌아갑니다. 이 구조는 큰 npm 트리를 매번 읽는 비용을 줄이면서 비핵심 파일의 통상적인 추가·삭제·이름 변경·내용 변경에는 전체 검증을 강제하고, 핵심 파일 내용 변경은 즉시 거부합니다. 캐시 필드와 핵심 파일 스탬프가 없는 스키마 1 영수증은 자동 승격하지 않고 실패 처리하므로, 기존 동일 버전 설치는 수명주기 스크립트를 끈 안전한 재설치 경로를 거쳐 스키마 2 영수증을 새로 받습니다. 단, 같은 사용자 권한이 비핵심 파일 내용과 모든 기록 메타데이터를 함께 복원하는 공격은 빠른 캐시의 신뢰 경계 밖이며 `SECURITY.md`에 잔여 위험으로 명시합니다.

### 구조화 로그와 진단 번들

실행 로그는 기본 상태 루트 아래에 구조화된 형식으로 저장합니다. 로그와 체크포인트는 허용된 진단 정보만 기록하고 알려진 개인정보·토큰·비밀값을 제거합니다. `Bundle`은 네트워크 연결 없이 정제된 로그, 체크포인트, 준비 상태와 버전 정보를 ZIP으로 묶습니다. `-DiagnosticOutputPath`로 저장 위치를 선택할 수 있으며, 생성된 파일은 자동 업로드하거나 전송하지 않습니다.

### 안정적인 실패 계약

사용자 화면에는 실패 원인, 다음 행동, 안정적인 오류 코드와 정제 로그 경로를 함께 표시합니다. PowerShell 내부 예외 원문보다 사용자가 다시 시도하거나 진단 번들을 만들 수 있는 안내를 우선합니다.

### 원격 파이프 실행 금지

`Invoke-WebRequest ... | Invoke-Expression` 형태를 사용하지 않습니다. 패키지 릴리스·소스 커밋과 별도로 검토한 공식 설치 스크립트 커밋을 고정하고, 스크립트를 먼저 파일로 받은 뒤 출처·리디렉션·크기·문법·고정 SHA-256을 검사합니다. 검증이 끝난 파일만 고정 인수와 정리된 환경을 사용하는 별도 PowerShell 프로세스에서 실행합니다.

### 숨은 전제조건 다운로드 차단

공식 설치 스크립트가 Git을 찾지 못할 때 별도의 최신 휴대용 Git을 받을 수 있으므로, 실행 전에 Authenticode 서명과 설치 위치를 확인한 Git for Windows를 준비합니다. Git이 없거나 신뢰할 수 없으면 WinGet의 고정된 `Git.Git` 버전만 설치하며, 격리된 설치 환경에는 검증된 Git 경로만 전달합니다.

### 공식 설정 API와 freshness 경계

0.4 설정 엔진은 OpenClaw `v2026.7.1`의 공식 CLI 계약만 사용하고 활성 설정 파일을 직접 쓰지 않습니다. 계획 생성 시 `config schema`, `config validate --json`, `config file`을 호출해 스키마와 기존 설정 파일의 SHA-256을 계획에 묶습니다. 사용자에게는 비밀값이 포함되지 않은 merge patch, 정확히 교체할 Easy Setup 소유 경로, 의미 요약과 계획 지문을 보여주며, `config patch --stdin --dry-run --json`이 성공해야 승인할 수 있습니다.

적용 직전에는 계획 지문, OpenClaw 버전, 스키마 해시, 설정 경로와 기존 설정 해시를 다시 계산합니다. resolver와 자격 증명을 준비한 뒤 `--allow-exec` dry-run을 통과해도 같은 freshness 검사를 한 번 더 수행합니다. 그 사이 스키마나 설정이 바뀌었다면 patch를 쓰지 않고 새 미리보기를 요구합니다. 실제 변경은 미리보기와 지문 검증에 사용된 같은 patch 객체와 `--replace-path` 집합을 다시 `config patch --stdin`으로 전달합니다.

### 안전한 설정 patch

마법사는 OpenAI·Anthropic·Google 중 하나와 해당 버전에서 검토된 모델을 선택합니다. 기존 설정을 가능한 한 유지하는 merge patch에 다음 기본값을 추가합니다. 단, resolver 공급자, Gateway 인증, 기본 모델, 선택 모델 공급자와 선택 채널은 계획에 묶인 정확 교체 경로입니다. 이 경계는 이전 사용자 지정 API 주소·header·채널 전송 설정이 새 자격 증명을 받는 것을 막습니다.

- Gateway `mode=local`, `bind=loopback`, token 인증과 요청 제한
- Tailscale 노출과 Gateway terminal 비활성화
- `session.dmScope=per-channel-peer`
- `tools.profile=messaging`과 runtime, filesystem, automation, UI, node, plugin, MCP bundle 그룹 명시적 차단
- elevated 도구 비활성화
- 선택한 Slack에 Socket Mode, bot/app SecretRef, `dmPolicy=pairing`, 채널·그룹 DM 차단, mention 필수, native/slash 명령·bot 메시지·이름 매칭·`configWrites` 차단
- 선택한 Telegram/Discord에 `dmPolicy=pairing`, `groupPolicy=disabled`, `configWrites=false`

채널은 선택 사항이며 선택하지 않은 채널은 patch에 넣지 않습니다. 선택한 채널 객체는 표시된 안전 기본값으로 정확히 교체되고, 선택하지 않은 채널은 유지됩니다. 공개 네트워크, 그룹 대화, 채널을 통한 설정 쓰기 또는 파일·명령 실행 권한을 마법사가 자동 활성화하지 않습니다.

### Credential Manager와 exec SecretRef

모델 키, Slack Bot User OAuth Token·App-Level Token과 선택한 봇 토큰은 WPF `PasswordBox`에서 `SecureString`으로 복사하고, Gateway용 256-bit 토큰은 프로세스 안에서 새로 생성합니다. 각 적용 계획은 128-bit 실행 ID를 포함하는 자격 증명 ID를 사용하므로 기존 자격 증명을 덮어쓰지 않습니다. 비밀값은 현재 Windows 사용자의 Credential Manager에 저장하고 OpenClaw patch에는 다음 세 요소만 넣습니다.

```text
source=exec
provider=oces_wincred
id=v1/<허용된 용도>/<run-id>
```

상태 폴더의 `State\Resolver` 아래에 빌드되는 네이티브 resolver는 OpenClaw exec SecretRef 프로토콜 v1 JSON을 표준 입력과 표준 출력으로 처리합니다. 허용된 자격 증명 ID 패턴만 `CredReadW`로 조회하며 셸, 스크립트, 인수, 환경 변수 또는 임시 파일을 비밀 전달 경로로 사용하지 않습니다. resolver 경로와 상위 폴더는 재분석 지점 및 현재 사용자 전용 ACL 조건을 fail-closed로 검사합니다.

Credential Manager는 평문 설정 파일 노출을 줄이지만 같은 Windows 사용자로 실행되는 프로세스와의 격리 수단은 아닙니다. OpenClaw와 resolver가 API 요청을 만들 때는 비밀값이 런타임 메모리에 존재합니다.

### 적용과 사후 검사

사용자가 dry-run 미리보기를 확인한 뒤 기본적으로 꺼진 승인 체크를 직접 선택해야 적용 버튼이 활성화됩니다. Slack 플러그인은 앞선 설치 단계에서 공식 `@openclaw/slack@2026.7.1`로 고정되며, 설정 엔진은 ID·버전·npm 출처·integrity·shasum·로드 상태·Slack capability를 다시 읽기 전용으로 검사합니다. 자격 증명 저장 뒤의 `--allow-exec` dry-run은 exec SecretRef 해석이 완전하고 건너뛴 참조가 0개인지 확인합니다. patch 적용 직후 파일 SHA-256을 기록합니다. 사후 검사에서 플러그인 출처, 이 바이트 지문, `config validate`, loopback·최소 권한·채널 안전 불변 조건이 모두 통과한 뒤에만 Gateway 서비스를 설치·재시작합니다. 하나라도 실패하면 Gateway 변경을 건너뛰고 실패로 기록한 뒤, `secrets audit --check --allow-exec`, `security audit --deep`, 모델 상태, 선택한 채널 probe와 Gateway RPC 상태를 검사합니다. Slack probe는 bot token만 확인하므로 bot/app SecretRef 가용성, runtime 실행과 Socket 연결까지 함께 성공해야 합니다.

첫 Credential Manager 쓰기 전에는 private State 폴더에 계획 지문, 정확한 자격 증명 ID, 적용 전후 설정 해시, 정제된 검사 상세를 담는 비밀값 없는 `Preparing` 복구 기록을 원자적으로 만듭니다. patch가 성공하면 사후 검사 전에 `AppliedPendingChecks`, 검사 뒤에는 `Succeeded` 또는 `Partial`로 원자 전환합니다. 설정 patch 전 실패하고 기존 설정 해시가 그대로면 이번 실행에서 실제로 만든 정확한 자격 증명 ID만 삭제하고 `RolledBack`으로 끝냅니다. patch 뒤에는 자동 롤백하지 않습니다.

GUI 시작과 새 적용은 미완료 복구 기록을 먼저 검사하고, 손상되었거나 여러 개면 fail-closed로 차단합니다. 적용 후의 일반 재검사는 Gateway를 바꾸지 않는 읽기 전용 경로입니다. 서비스 재시작, 자격 증명 교체 또는 변경된 설정에 승인 patch를 다시 적용하는 작업은 별도의 GUI 승인 뒤에만 실행합니다. 사용자가 모델·채널 자격 증명을 다시 입력하면 기존 실행의 같은 ID에만 교체하고 생성된 Gateway token은 보존합니다. 교체 시작 전에 영속적인 전체-세트 pending marker를 남기며, 중단되면 기록에 묶인 모델과 선택 채널 비밀을 모두 다시 입력해 완전히 교체하기 전에는 marker를 없애지 않습니다.

복구 성공 전에는 receipt의 OpenClaw 버전·schema 해시·활성 설정 경로가 현재 공식 CLI와 일치하는지 먼저 확인하고, 호환되지 않으면 어떤 복구 변경도 시작하지 않습니다. 이어 성공한 정확 교체 patch 직후의 설정 파일 해시가 유지되는지, loopback Gateway·최소 권한 도구·채널 불변 조건이 유지되는지 확인합니다. 민감 경로를 가리는 `config get` 결과는 정확한 SecretRef 증거로 사용하지 않습니다. 설정 해시가 달라졌다면 별도의 `-AcceptConfigChange` 승인 아래 기록에 지문으로 묶인 patch를 Easy Setup 소유 경로에 재적용하고 새 해시를 원자적으로 기록한 뒤에만 재시작·검사를 진행합니다. 전체 검사 뒤 해시를 다시 계산해 검사 도중의 변경도 `Partial`로 처리합니다. 공식 고급 설정으로 넘길 때도 자식 프로세스 종료를 기다리며 일부 적용 상태를 성공으로 바꾸지 않습니다. 설정 마법사를 열거나 미리보기만 하는 경로는 Credential Manager와 OpenClaw 설정을 변경하지 않습니다.

## 신뢰 경계

- 이 도구의 저장소와 릴리스
- `config/openclaw-source.json`에 승인된 공식 다운로드 호스트
- 다운로드된 설치 파일
- 검토된 OpenClaw `v2026.7.1` 설정 스키마와 CLI 계약
- 현재 Windows 사용자의 Credential Manager와 검증된 네이티브 resolver
- OpenClaw Gateway 및 사용자가 연결한 모델·메신저

각 경계에서는 문자열 기반 신뢰 대신 HTTPS 제한, 해시, 서명 상태, 스키마 dry-run, freshness 확인, 명시적 승인, 최소 권한과 사후 보안 감사를 조합합니다. 같은 Windows 사용자 권한의 악성 프로세스와 런타임 메모리는 Credential Manager 경계 밖의 잔여 위험입니다.
