# 쉬운 설정 마법사 0.4

OpenClaw Easy Setup 0.4는 모델 제공자와 선택한 메신저를 안전한 기본값으로 연결하는 Windows용 마법사입니다. 검토 기준은 OpenClaw `v2026.7.1`이며, 이 프로젝트는 OpenClaw 공식 프로젝트가 아닙니다.

## 시작하기

`Start-OpenClawEasySetup.cmd`를 두 번 클릭하고 메인 화면에서 `OpenClaw 설정`을 선택합니다. 설정 마법사를 열거나 입력하고 미리보기만 하는 동안에는 OpenClaw 설정과 Windows Credential Manager가 바뀌지 않습니다.

1. 제공자와 모델을 선택합니다.
2. 모델 API 키를 입력합니다.
3. Slack을 사용하면 가장 위의 Slack을 선택하고 Bot User OAuth Token과 `connections:write` App-Level Token을 입력합니다. 필요하면 Telegram 또는 Discord도 선택합니다.
4. `변경 미리보기`를 눌러 공식 dry-run 결과, 변경 요약, 비밀값이 제거된 JSON patch와 계획 지문을 확인합니다.
5. 내용이 맞을 때만 기본적으로 꺼져 있는 승인 체크를 선택하고 `설정 적용`을 누릅니다.

지원되는 간편 선택은 다음과 같습니다.

| 제공자 | 모델 |
|---|---|
| OpenAI | `openai/gpt-5.6`, `openai/gpt-5.5` |
| Anthropic | `anthropic/claude-opus-4-8`, `anthropic/claude-sonnet-5` |
| Google | `google/gemini-3.1-pro-preview`, `google/gemini-3-flash-preview` |

이 목록에 없는 제공자·인증 방식·채널 설정이 필요하면 `공식 고급 설정`을 사용하세요. 별도의 보이는 콘솔에서 기존 OpenClaw 온보딩 흐름을 엽니다.

## 적용되는 안전 기본값

| 영역 | 기본값 |
|---|---|
| Gateway | `mode=local`, `bind=loopback`, token 인증, Tailscale 끔, terminal 끔 |
| Gateway token | 마법사가 새로 생성하는 256-bit 난수 |
| 세션 | `dmScope=per-channel-peer` |
| 도구 | `messaging` 프로필 |
| 명시적 차단 | runtime, filesystem, automation, UI, nodes, plugins, MCP bundle, elevated |
| Slack | Socket Mode, DM `pairing`, 채널·그룹 DM `disabled`, mention 필수, native/slash 명령·bot 메시지·이름 매칭·`configWrites` 차단 |
| Telegram | DM `pairing`, 그룹 `disabled`, `configWrites=false` |
| Discord | DM `pairing`, 서버 그룹 `disabled`, `configWrites=false` |

Slack, Telegram과 Discord는 선택 사항입니다. 선택하지 않은 채널은 patch에 포함하지 않으므로 기존 채널 설정을 자동으로 끄거나 덮어쓰지 않습니다. 선택한 채널과 모델 공급자, Gateway 인증, 기본 모델, Credential Manager resolver 공급자는 미리보기에 표시된 Easy Setup 소유 경로로서 정확히 교체됩니다. 따라서 기존의 사용자 지정 API 주소·header·채널 전송 설정은 선택한 새 키나 토큰을 받지 않습니다. 나머지 설정은 merge로 유지됩니다.

## Slack을 처음 준비할 때

설치 단계가 공식 `@openclaw/slack@2026.7.1` 플러그인을 본체와 같은 버전으로 준비하고 npm integrity·shasum을 확인합니다. 설정 전에 [고정 커밋의 공식 Slack 문서](https://github.com/openclaw/openclaw/blob/2d2ddc43d0dcf71f31283d780f9fe9ff4cc04fe4/docs/channels/slack.md)의 **Quick setup → Socket Mode**를 엽니다. Slack 앱 관리 화면에서 **Create New App → From a manifest**를 선택하고 문서의 권장 또는 최소 manifest를 붙여 넣어 앱을 만든 뒤 **Install to Workspace**까지 완료하세요. manifest가 필요한 bot OAuth scope와 message/app mention 이벤트 구독을 함께 설정합니다. 수동으로 scope나 이벤트를 줄이면 연결 검사는 통과해도 메시지가 도착하지 않을 수 있습니다.

1. Bot User OAuth Token: 일반적으로 `xoxb-`로 시작합니다.
2. App-Level Token: 일반적으로 `xapp-`로 시작하며 `connections:write` 권한이 필요합니다.

접두사는 안내용이며 도우미가 토큰 값을 로그에 남기거나 문자열 규칙만으로 진위를 판단하지 않습니다. 적용 후 자동 검사는 두 SecretRef 상태, Gateway의 Slack runtime 실행·Socket 연결과 bot probe를 확인하지만 실제 메시지 왕복까지 증명하지는 않습니다. Slack에서 설치한 봇에게 개인 DM을 보내고 공식 pairing 절차로 승인한 뒤 답장이 오는지 직접 확인하세요. 최초 Easy Setup은 개인 DM 페어링만 열며 Slack 채널과 그룹 DM은 차단합니다. 공개 채널을 나중에 허용하려면 공식 고급 설정에서 이름 대신 `C...` 채널 ID를 사용하세요.

## 적용 전 검사

마법사는 설치 영수증으로 검증된 OpenClaw 실행 경로를 사용하고 다음 순서로 검사합니다.

```text
config schema
config validate --json
config file
config patch --stdin --dry-run --json
```

공식 스키마 JSON과 현재 설정 파일의 SHA-256, 설정 경로, OpenClaw 버전, 선택 항목, patch와 정확 교체 경로를 하나의 계획 지문에 묶습니다. 미리보기 뒤 스키마나 설정이 바뀌면 적용하지 않고 새 미리보기를 요구합니다.

비밀값을 Credential Manager에 저장한 뒤에는 `--allow-exec`을 추가한 두 번째 dry-run으로 resolver를 포함한 SecretRef 해석을 확인합니다. 이 검사는 `checks.resolvabilityComplete=true`이고 `skippedExecRefs=0`일 때만 통과합니다. 이어서 freshness를 다시 확인하고 미리본 것과 같은 patch 및 `--replace-path` 집합을 `config patch --stdin`으로 적용합니다.

## 비밀정보 저장 방식

API 키와 봇 토큰은 WPF `PasswordBox`로 입력합니다. Gateway token은 마법사가 생성합니다. 이 값들은 다음 위치에 평문으로 기록하지 않습니다.

- OpenClaw 설정 JSON
- 미리보기와 계획 지문
- 프로세스 명령줄과 환경 변수
- 임시 파일, 로그, 체크포인트, 진단 ZIP

각 비밀값은 현재 Windows 사용자의 Credential Manager에 `OpenClawEasySetup:` 접두사와 실행별 고유 ID로 저장됩니다. OpenClaw 설정에는 `source=exec`, `provider=oces_wincred`, 허용된 ID를 가진 SecretRef만 들어갑니다.

네이티브 resolver는 OpenClaw exec SecretRef 프로토콜 v1 요청을 표준 입력으로 받고 Credential Manager에서 정확한 ID를 조회한 뒤 JSON 응답을 표준 출력으로 돌려줍니다. 임의 명령이나 셸을 실행하지 않으며, 허용 목록 밖 ID와 안전하지 않은 resolver 경로·ACL을 거부합니다.

Credential Manager는 설정 파일의 평문 노출을 줄이지만 **같은 Windows 사용자로 실행되는 다른 프로세스와 비밀값을 격리하지는 않습니다**. OpenClaw와 resolver가 연결할 때 비밀값은 프로세스 메모리에 잠시 존재합니다. Windows 계정을 공유하거나 이미 침해된 계정에서 이 기능을 보안 경계로 간주하면 안 됩니다.

## 적용 후 검사

patch가 적용되면 다음을 확인합니다.

- 설정 유효성
- 승인된 정확 교체 patch 직후 설정 파일의 SHA-256 연속성
- 위 설정 지문·유효성·안전 불변 조건이 모두 통과한 뒤의 Gateway 서비스 설치와 재시작
- exec SecretRef 감사
- 심층 보안 감사
- 모델 상태
- 고정 Slack 플러그인 출처·runtime 검사와 선택한 Slack/Telegram/Discord probe
- Gateway RPC 상태

사후 검사 하나라도 실패하면 성공으로 표시하지 않습니다. 다만 patch 적용 후의 실패는 자동 롤백되지 않습니다. 화면에는 실패한 검사, 종료 코드 또는 의미 검증 실패 이유와 정제된 세부 정보가 표시됩니다. 적용이 시작된 각 시도는 첫 Credential Manager 쓰기 전에 현재 사용자와 SYSTEM만 읽을 수 있는 `State\settings-<계획 지문>.json` 복구 기록을 `Preparing` 상태로 만듭니다. patch 직후에는 `AppliedPendingChecks`, 검사 완료 뒤에는 `Succeeded` 또는 `Partial`로 원자 갱신합니다. 기록에는 정확한 Credential Manager ID, 적용 전후 설정 해시와 정제 결과만 남기며 비밀값은 넣지 않습니다.

마법사는 시작할 때 `Preparing`, `AppliedPendingChecks`, `Partial` 기록을 먼저 검사하고 새 적용을 차단합니다. `Preparing`에서는 `중단 작업 자격 증명 정리`가 설정 해시가 그대로일 때 이번 실행의 정확한 ID만 삭제합니다. 적용 후 상태의 `읽기 전용 사후 검사`는 Gateway를 설치·재시작하거나 자격 증명을 바꾸지 않습니다. 서비스 재시작이 필요하면 비밀 입력을 비워둔 채 별도 승인하고 `Gateway 재시작 및 재검사`를 누릅니다. API 키나 봇 토큰을 잘못 입력했다면 기록에 묶인 모델·채널 비밀 입력을 **모두** 채운 뒤 같은 승인 경로를 사용하여 같은 ID에 교체할 수 있습니다. 자격 증명 교체가 중간에 끊기면 복구 기록이 `Credential replacement pending`을 남기며, 다음 실행은 모델과 선택한 모든 채널 비밀을 다시 입력해 전체 세트를 완전히 다시 쓰기 전에는 성공으로 진행하지 않습니다. 생성된 Gateway token은 유지하며 새 ID를 만들거나 접두사 전체를 정리하지 않습니다.

고급 설정 등으로 현재 설정 파일의 해시가 복구 기록과 달라졌다면 GUI는 그 상태를 자동 성공 처리하지 않습니다. 먼저 읽기 전용 검사를 실행해 `Configuration drift recovery authorization` 실패를 확인합니다. 화면의 `승인된 Easy Setup 패치 복원 동의`를 선택하면 현재 설정 전체를 신뢰하지 않고, 다른 사용자 설정은 유지하면서 기록의 계획 지문에 묶인 Gateway 인증·기본 모델·선택 공급자·선택 채널·resolver 경로만 이전 안전 patch로 복원합니다. 복원 직후 새 해시를 기록한 뒤 전체 검증과 Gateway 재시작을 실행합니다. PowerShell 운영자는 설정 모듈을 직접 가져온 뒤 `Invoke-OpenClawSafeSetupRecoveryVerification -AcceptConfigChange -EnsureGatewayService -Confirm:$false`를 사용할 수도 있습니다.

해시 변경 복구를 승인해도 복구 기록의 OpenClaw 버전·`config schema` 해시·활성 설정 경로가 현재 공식 CLI와 먼저 일치해야 합니다. 이 호환성은 자동으로 새 버전에 맞춰 다시 설정되지 않으며, 다르면 모든 resolver·Credential Manager·patch·Gateway 변경 전에 `Partial`로 멈춥니다. 호환성이 확인된 후에도 승인 patch 직후의 새 설정 해시, loopback Gateway와 최소 권한 도구·채널 불변 조건이 모두 일치해야 성공할 수 있습니다. 고정 OpenClaw 버전은 민감 경로의 `config get` 결과를 가리므로 SecretRef ID를 다시 읽는 대신, 성공한 정확 교체 patch와 직후 바이트 해시를 값 노출 없는 바인딩 증거로 사용합니다. 검사 도중 설정 해시가 다시 달라져도 `Partial`로 남습니다. 복구 기록이 손상되었거나 둘 이상 미완료 상태라면 자동 복구와 새 적용을 모두 중단하고 수동 검토를 요구합니다. `공식 고급 설정`을 선택해도 기존 일부 적용 상태는 사후 검증 전까지 성공으로 바뀌지 않습니다.

Slack이 추가된 현재 마법사는 계획과 복구 기록 스키마 2를 사용합니다. 이전 스키마 1의 검증된 완료 기록은 새 설정을 막지 않지만, 미완료 기록은 자동 변환하지 않고 모든 새 적용과 복구 변경을 차단합니다. 이때 `State\settings-<계획 지문>.json`을 삭제하거나 편집하지 마세요. 기록을 만든 이전 Easy Setup 버전으로 마무리하거나 수동으로 설정과 Credential Manager 상태를 검토해야 하며, 도움을 요청할 때도 토큰이나 영수증 본문은 공유하지 마세요.

## 문제가 있을 때

- `기존 설정이 유효하지 않음`: 공식 OpenClaw 복구 또는 고급 설정으로 기존 설정을 먼저 고칩니다.
- `schema/config가 미리보기 뒤 변경됨`: 다른 OpenClaw 작업을 마친 뒤 `변경 미리보기`부터 다시 실행합니다.
- `dry-run 거부`: 현재 설치된 OpenClaw 버전과 이 저장소의 고정 버전이 맞는지 확인합니다.
- `resolver/ACL 거부`: 상태 폴더를 공유·동기화·재분석 지점이 아닌 현재 사용자 전용 로컬 폴더로 바꿉니다.
- `Slack 플러그인 검사 실패`: 설치 상태 확인을 다시 실행합니다. 다른 출처·버전의 `slack` 플러그인은 자동 덮어쓰기하지 않습니다.
- `Gateway 또는 채널 probe 실패`: 토큰을 GitHub Issue에 올리지 말고, 정제된 진단 ZIP과 오류 코드만 공유합니다.

더 자세한 보안 경계는 [보안 정책](../SECURITY.md), 내부 흐름은 [아키텍처](architecture.md)를 참고하세요.
