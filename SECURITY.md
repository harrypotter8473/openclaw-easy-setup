# Security policy

이 프로젝트는 설치 스크립트를 다운로드하고 로컬 에이전트 설정을 다루므로 일반적인 편의 도구보다 좁은 신뢰 경계를 사용합니다.

## 민감정보

다음 자료를 GitHub Issue, Pull Request, 로그 또는 스크린샷에 올리지 마세요.

- 모델 제공자 API 키와 OAuth 토큰
- 메신저 봇 토큰과 페어링 코드
- OpenClaw Gateway 인증 토큰
- `.env`, `openclaw.json`, `~/.openclaw` 내용
- 사용자 홈 경로가 포함된 전체 진단 로그

실수로 커밋했다면 파일만 삭제하지 말고 즉시 자격 증명을 폐기·재발급한 다음 Git 기록에서도 제거해야 합니다.

## 설치 파일 신뢰 정책

현재 MVP는 다음을 강제합니다.

1. 설치 출처는 `https`여야 합니다.
2. 최초 주소와 모든 리디렉션의 호스트가 명시적 허용 목록에 있어야 합니다.
3. 기존 파일을 덮어쓰지 않는 고유 임시 파일을 사용합니다.
4. OpenClaw 릴리스·패키지 소스 커밋과 공식 설치 스크립트 커밋·SHA-256을 리뷰된 매니페스트에 각각 고정합니다.
5. 응답 크기, PowerShell 문법, SHA-256 중 하나라도 예상과 다르면 실행하지 않습니다.
6. 검증된 설치 파일로 `-DryRun`이 성공한 뒤에만 실제 설치를 허용합니다.
7. 설치 방식과 OpenClaw 패키지 버전을 고정하며 `latest`, `main`, `beta`를 실행하지 않습니다.
8. 임시 설치 파일은 기본적으로 제거합니다.

Slack 지원은 별도 공급망 경계입니다. 공식 `@openclaw/slack@2026.7.1`의 정확한 설치 spec, npm integrity와 shasum을 매니페스트에 고정합니다. OpenClaw의 플러그인 설치기가 npm 수명주기 스크립트를 끈 관리 디렉터리에 설치한 뒤 `plugins inspect slack --runtime --json`의 ID·버전·활성·로드 상태·채널 capability·설치 기록을 모두 대조합니다. 이미 다른 출처나 버전의 `slack` 플러그인이 있으면 자동 교체하지 않고 중단합니다.

runtime 코드를 처음 불러오기 전에는 비실행 `plugins inspect slack --json`으로 설치 기록의 exact spec·버전·integrity·shasum과 활성 소스 경로를 먼저 대조합니다. 이 검사는 npm에서 받은 아카이브의 설치 출처를 묶지만, 압축 해제된 플러그인 파일 전체를 별도 Easy Setup 영수증으로 매번 다시 해시하는 기능은 아직 아닙니다. 같은 Windows 사용자 권한이 이미 침해되어 설치 파일과 OpenClaw 상태를 함께 바꿀 수 있는 경우를 보안 경계로 간주하지 않습니다.

Git for Windows와 Node.js 자동 준비는 WinGet의 정확한 패키지 ID(`Git.Git`, `OpenJS.NodeJS`), 소스(`winget`), 버전을 지정합니다. `--force`나 보안 해시 무시 옵션은 사용하지 않으며 설치 후 정확한 버전과 실행 파일의 Authenticode 서명을 다시 검사합니다. 공식 OpenClaw 설치 스크립트에는 검증된 `git.exe`와 지원되는 `node.exe`만 보이는 격리된 `PATH`를 전달해, 설치 스크립트의 고정되지 않은 휴대용 Git·Node 다운로드 경로가 실행되지 않게 합니다.

설치 성공 직후 OpenClaw 패키지 파일 트리와 명령 shim의 SHA-256을 현재 사용자 전용 상태 폴더에 기록합니다. 이후 온보딩과 검증은 이 무결성 영수증이 현재 고정 출처·사용자·버전·파일과 모두 일치할 때만 OpenClaw 코드를 실행합니다. 같은 버전의 외부 설치나 손상된 영수증은 기존 패키지 코드를 실행하거나 새 영수증을 임의로 발급하지 않습니다. npm 수명주기 스크립트를 끈 제거 후 고정 버전을 새로 설치해 복구합니다.

무결성 영수증 스키마 2는 설치 직후 계산한 전체 콘텐츠 트리 SHA-256을 보존하면서, 파일의 상대 경로·크기·생성/수정 UTC 시각·속성을 묶은 결정적 메타데이터 트리 SHA-256도 기록합니다. 일상 검증에서는 메타데이터 트리와 명령 shim, 패키지 진입점, `package.json`의 콘텐츠 SHA-256을 확인합니다. 메타데이터가 달라지면 보존한 전체 콘텐츠 트리 해시로 자동 재검증하며, 핵심 세 파일은 메타데이터가 같아도 항상 콘텐츠 해시로 검사합니다.

이 빠른 경로는 같은 Windows 사용자 권한의 악성 프로세스에 대한 보안 격리 경계가 아닙니다. 그 프로세스는 비핵심 패키지 파일의 내용을 바꾼 뒤 경로·크기·생성/수정 시각·속성을 모두 정확히 복원해 메타데이터 캐시를 우회하거나, 현재 사용자 소유의 패키지와 영수증 자체에 접근할 수 있습니다. 따라서 이 캐시는 일반적인 손상과 변경을 빠르게 감지하기 위한 장치이며, 같은 사용자 계정이 이미 장악된 상황을 방어한다고 간주하지 않습니다.

현재 패키지 고정값은 공식 GitHub 릴리스와 소스 커밋에서, 설치 스크립트 고정값은 Windows PowerShell 5.1 수정이 반영된 별도 공식 커밋에서 각각 독립적으로 검토한 값입니다. 공식 프로젝트가 별도 신뢰 채널로 체크섬 또는 코드 서명을 제공할 때 이를 기본 검증 경로로 승격해야 합니다.

## GUI 신뢰 경계

- GUI는 일반 사용자 권한으로 실행하며 WinGet, npm 또는 다운로드 코드를 직접 실행하지 않습니다.
- 별도 작업 프로세스는 OS가 알려주는 Windows 시스템 폴더에서 Microsoft가 서명한 Windows PowerShell만 사용합니다.
- Windows PowerShell 진입점은 프로세스에 상속된 모듈 검색 경로를 사용하지 않고 해당 시스템 PowerShell의 기본 모듈 폴더만 사용합니다.
- 설치와 재개는 사용자가 본 계획의 SHA-256 지문이 실행 직전 계획과 일치할 때만 허용합니다.
- 동의 체크와 시작 버튼은 기본적으로 꺼져 있고 Enter, Escape와 창 닫기는 설치 승인으로 처리하지 않습니다.
- 설치 취소는 개인 상태 폴더 안의 검증된 신호 파일을 사용합니다. 실행 중인 외부 프로그램을 강제로 종료하지 않고 단계 사이에서 멈춥니다.
- GUI 전체를 `runas`로 올리지 않습니다. Git·Node.js가 필요할 때 고정된 WinGet 설치 단계가 Windows 권한 확인을 표시할 수 있습니다.
- 공식 대화형 온보딩은 설치 작업과 분리된 보이는 콘솔에서 실행하며 비밀값을 GUI 로그나 프로세스 인수로 전달하지 않습니다.
- 로그와 진단 ZIP은 로컬에만 저장하고 자동 업로드하지 않습니다.

`Start-OpenClawEasySetup.cmd`는 서명되지 않은 개발 단계 스크립트를 시작하기 위해 해당 Windows PowerShell 프로세스에만 `ExecutionPolicy Bypass`를 적용합니다. 시스템 또는 사용자 실행 정책을 영구 변경하지 않습니다. 코드 서명된 1.0 배포에서는 이 임시 실행 경로를 제거할 예정입니다.

현재 `.cmd` 개발용 시작 파일은 PowerShell 검증 코드가 실행되기 전에 Windows 배치 환경의 `%SystemRoot%`를 한 번 사용합니다. 따라서 일반 Windows Explorer에서 직접 실행하는 흐름을 전제로 하며, 상위 프로세스가 환경 변수를 변조할 수 있는 위협 모델까지 보호하지는 않습니다. 시작된 GUI는 OS가 제공하는 실제 시스템 디렉터리와 Microsoft 서명을 다시 확인한 PowerShell만 작업 프로세스로 사용합니다. 이 부트스트랩 한계는 1.0의 코드 서명된 시작 프로그램으로 제거할 예정입니다.

## 쉬운 설정과 자격 증명 신뢰 경계

0.4 쉬운 설정은 검토한 OpenClaw `v2026.7.1` 설정 계약을 대상으로 합니다. 활성 설정 파일을 직접 편집하지 않고 다음 공식 CLI 경계를 사용합니다.

1. `config schema`의 JSON을 읽고 SHA-256을 기록합니다.
2. `config validate --json`으로 기존 설정이 유효한지 확인하고 설정 파일의 SHA-256을 기록합니다.
3. 비밀값이 제거된 merge patch, 정확히 교체할 Easy Setup 소유 경로와 계획 지문을 사용자에게 보여줍니다.
4. `config patch --stdin --dry-run --json`으로 공식 스키마 검사를 통과해야 승인할 수 있습니다.
5. 적용 직전에 스키마·설정 경로·설정 파일 SHA-256과 계획 지문을 다시 확인합니다. 하나라도 달라지면 쓰기를 중단하고 새 미리보기를 요구합니다.
6. 자격 증명을 저장한 뒤 `--allow-exec` dry-run으로 SecretRef resolver까지 검사하고 freshness 검사를 한 번 더 수행한 다음, 같은 패치와 지문에 묶인 `--replace-path` 집합을 적용합니다. resolver 공급자, Gateway 인증, 기본 모델, 선택 모델 공급자와 선택 채널 객체는 정확히 교체되어 이전 `env`, 사용자 지정 `baseUrl`·header 또는 채널 전송 설정이 남지 않습니다.

모델 API 키, Slack Bot User OAuth Token·App-Level Token, Telegram/Discord 봇 토큰 입력은 WPF `PasswordBox`에서 받고 Gateway 토큰은 암호학적 난수 256-bit 값으로 생성합니다. Slack 두 값도 `channels.slack.botToken`과 `channels.slack.appToken`의 별도 SecretRef로만 연결합니다. 비밀값은 계획, 미리보기, OpenClaw 설정 JSON, 프로세스 인수, 환경 변수, 임시 파일, 로그에 넣지 않습니다. OpenClaw 설정에는 다음 형태의 SecretRef와 resolver 제공자 정보만 기록합니다.

```json
{"source":"exec","provider":"oces_wincred","id":"v1/.../<run-id>"}
```

각 적용 시도는 예측 불가능한 128-bit 실행 ID를 포함한 새 자격 증명 ID를 사용합니다. 이미 존재하는 ID에는 덮어쓰지 않으며, 첫 자격 증명 쓰기 전에 현재 사용자와 SYSTEM으로 ACL이 제한된 State 폴더에 `Preparing` 복구 기록을 원자적으로 만듭니다. 설정 패치 전 실패하고 기존 설정 해시가 그대로면 이번 시도에서 실제로 만든 정확한 ID만 삭제합니다. patch 직후에는 `AppliedPendingChecks`, 검사 후에는 `Succeeded` 또는 `Partial`로 기록을 원자 갱신합니다. 광범위한 Credential Manager 열거 또는 접두사 기반 정리를 하지 않습니다. 복구 기록에는 정확한 ID, 계획 지문, 설정 해시와 정제된 검사 상세만 넣고 자격 증명 값이나 OpenClaw 명령의 원문 출력은 넣지 않습니다.

시작 시 미완료·손상·복수 복구 기록은 새 적용보다 먼저 fail-closed로 처리됩니다. 적용 후 일반 재검사는 Gateway를 설치·재시작하지 않는 읽기 전용 경로입니다. Gateway 재시작, 모델·선택 채널 자격 증명의 같은-ID 교체 또는 설정 해시 변경 뒤 승인 패치 복원은 별도 사용자 승인 뒤에만 실행합니다. 자격 증명 전체 세트 교체 전에 `Credential replacement pending`을 원자적으로 기록하고, 중단되면 모델과 선택한 모든 채널 비밀을 다시 받아 완전한 세트를 다시 쓴 후의 완료 기록이 남을 때만 이 제약을 해제합니다. Gateway token은 회전하지 않습니다.

Slack 추가 이후의 계획 지문과 복구 기록은 스키마 2로 분리됩니다. 이전 스키마 1 기록은 ACL·사용자·지문·경로·자격 증명 ID·정제 결과를 이전 계약대로 모두 검증하며, 완료된 기록만 새 작업에서 건너뜁니다. 미완료 스키마 1 기록은 내용을 자동 변환하거나 실행하지 않고 Credential Manager·설정 patch·Gateway 변경 전에 고정된 안내로 중단합니다. 해당 파일을 편집하거나 삭제해 우회하지 말고, 기록을 만든 이전 버전으로 복구하거나 비밀값을 공유하지 않은 상태에서 수동 검토해야 합니다.

복구는 먼저 receipt에 묶인 OpenClaw 버전·`config schema` SHA-256·활성 설정 파일 경로가 현재 공식 CLI와 정확히 일치하는지 확인합니다. 다르거나 읽을 수 없으면 새 기준으로 자동 재설정하지 않고 resolver·Credential Manager·patch·Gateway 변경 전에 멈춥니다. 이어 성공한 정확 교체 패치 직후 기록한 설정 SHA-256의 연속성, loopback·최소 권한·채널 안전 불변 조건을 모두 검사합니다. 고정 OpenClaw 버전의 `config get`은 `apiKey` 같은 민감 경로의 하위 SecretRef 필드도 가리므로 정확한 ID 증거로 사용하지 않습니다. 대신 공식 patch 성공과 그 직후의 바이트 해시를 값 노출 없는 바인딩 증거로 사용합니다. 해시가 달라졌다면 GUI 또는 PowerShell에서 `-AcceptConfigChange`를 명시해야 하며, 현재 파일 전체를 신뢰하는 대신 기록의 지문에 묶인 patch를 Easy Setup 소유 경로에 다시 적용한 뒤 새 해시를 기록합니다. 전체 검사 뒤 다시 해시를 계산해 도중 변경도 실패 처리합니다.

resolver는 상태 폴더 아래의 검증된 일반 경로에 컴파일되는 네이티브 `.exe`입니다. 재분석 지점과 안전하지 않은 ACL을 fail-closed로 거부하며, OpenClaw exec SecretRef 프로토콜 v1 JSON을 표준 입력으로 받아 엄격한 허용 목록 형식의 ID만 조회합니다. 셸, 스크립트 파일, 명령줄 인수, 상속 환경 변수로 비밀값을 전달하지 않습니다. 오류에는 비밀값을 포함하지 않고 입력·출력 크기를 제한합니다.

### Credential Manager의 한계

- 자격 증명은 이 마법사를 실행한 **현재 Windows 사용자**의 Credential Manager에 저장됩니다. 다른 Windows 사용자나 원격 비밀 저장소로 자동 복제하지 않습니다.
- Credential Manager와 SecretRef는 `openclaw.json` 등의 평문 저장을 줄이기 위한 장치입니다. 같은 Windows 사용자 권한으로 실행되는 다른 프로세스에 대한 비밀정보 격리 경계가 아닙니다.
- 실제 사용 시 OpenClaw와 resolver 프로세스는 비밀값을 메모리에 잠시 복원합니다. 메모리 덤프, 디버거, 동일 사용자 계정 탈취까지 막는 설계는 아닙니다.
- 설정 마법사를 열거나 미리보기만 하는 동안에는 PC 설정과 Credential Manager가 바뀌지 않습니다. 사용자가 별도 승인 체크 후 `설정 적용`을 눌러야 변경됩니다.
- 설정 패치가 적용된 뒤 Gateway 재시작이나 사후 감사가 실패할 수 있습니다. 이 경우 적용된 설정을 자동 되돌리지 않으므로 결과 화면과 정제 로그를 확인한 뒤 문제를 해결해야 합니다.

적용 후 고정 Slack 플러그인 출처·runtime, 설정 바이트 지문 연속성, `config validate`, loopback·최소 권한·채널 안전 불변 조건이 **모두** 통과해야 Gateway 설치·재시작을 실행합니다. 하나라도 실패하면 두 Gateway 변경을 명시적으로 건너뛰고 실패로 기록합니다. 이어 `secrets audit --check --allow-exec`, `security audit --deep`, 모델 상태, 선택한 채널 probe와 Gateway RPC 상태를 확인합니다. Slack은 bot probe만으로 성공 처리하지 않고 bot/app token 상태, runtime 실행과 Socket 연결까지 요구합니다. 이 검사는 위험한 설정을 조용히 성공으로 표시하지 않기 위한 사후 검증이며, Windows 계정 자체가 침해된 경우의 보안 경계는 아닙니다.

## OpenClaw 기본 보안 방향

- Gateway는 로컬 전용으로 시작합니다.
- DM은 페어링 또는 허용 목록을 우선합니다.
- 공개 DM과 공개 네트워크 노출을 자동 활성화하지 않습니다.
- 도구 실행 권한과 파일 접근 범위는 최소 권한에서 시작합니다.
- 설정 변경 후 `openclaw doctor`와 `openclaw security audit --deep`을 실행합니다.
- 서로 신뢰하지 않는 사용자는 동일 Gateway를 공유하지 않습니다.

## 취약점 보고

공개 Issue에 악용 가능한 세부 정보나 비밀정보를 게시하지 마세요. 저장소에서 GitHub Private Vulnerability Reporting이 활성화되면 **Security → Report a vulnerability**를 사용합니다. 해당 기능이 활성화되기 전에는 재현 가능한 공격 코드를 공개하지 말고, 먼저 비공개 보고 채널을 마련하는 Issue를 민감 정보 없이 요청하세요.
