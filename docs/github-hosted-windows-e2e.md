# GitHub 임시 Windows에서 설치 E2E 실행하기

`Windows Install E2E`는 사용자의 PC가 아니라 GitHub가 실행마다 제공하고 작업 후 폐기하는 Windows runner에서 실제 신규 설치를 검사합니다. Windows Sandbox 기능, 드라이버, Hyper-V 설정을 변경하거나 사용자의 PC를 재부팅하지 않습니다.

## 실행 방법

워크플로 파일이 먼저 기본 브랜치에 병합되어 있어야 GitHub의 실행 버튼이 표시됩니다.

1. 저장소의 `Actions` 탭을 엽니다.
2. 왼쪽에서 `Windows Install E2E`를 선택합니다.
3. `Run workflow`를 누릅니다.
4. 기본 브랜치가 선택되어 있는지 확인하고 다시 `Run workflow`를 누릅니다. 다른 브랜치를 선택하면 checkout과 설치 전에 명시적으로 실패합니다.
5. 완료된 실행의 `Summary`에서 `PASS` 또는 `FAIL`과 단계별 상태를 확인합니다.

이 워크플로는 `workflow_dispatch`로만 시작할 수 있습니다. push, pull request, 예약 실행에서는 실제 설치가 자동으로 시작되지 않습니다.
Summary에는 실제로 checkout하고 검사한 40자리 commit SHA도 함께 표시됩니다.

## 검사 범위

- 고정된 OpenClaw 버전의 신규 설치 종료 코드
- GUID 체크포인트 하나의 스키마, 목표 버전, source fingerprint와 8단계 순서
- `diagnose`, `node`, `download`, `integrity`, `dryRun`, `install` 성공
- 온보딩과 토큰 입력이 명시적으로 건너뛰어졌는지
- 설치 영수증과 실제 npm 패키지 트리·중요 파일 digest 재검증
- 설치된 OpenClaw 버전이 고정 목표와 일치하는지
- Slack 플러그인의 고정 버전, npm integrity·shasum, 설치 위치와 runtime capability

## 안전 경계

- 저장소 권한은 `contents: read`뿐이며 checkout 자격 증명을 남기지 않습니다.
- API 키, Slack 토큰, 저장소 secret 또는 운영용 자격 증명을 전달하지 않습니다.
- 설치 프로세스 전에 환경변수를 최소 Windows 허용 목록으로 다시 만들고 토큰·secret·password·credential·API key 형태의 변수가 남으면 중단합니다.
- GitHub 도구 캐시의 Node.js를 PATH에서 제외하고 제품이 신뢰하는 Windows 경로만 사용합니다.
- `.git`, 문서와 설정·자격증명 코드는 worker에 전달하지 않습니다. 필요한 런타임 파일 7개만 runner 임시 폴더에 복사하고 실행 전후 SHA-256을 확인합니다.
- npm과 Git은 빈 사용자 설정 파일을 사용합니다.
- 원시 설치 stdout, stderr, 로그, 사용자 SID와 절대 경로는 Summary나 artifact로 올리지 않습니다.
- Summary에는 버전, 단계 ID·상태, 검증 Boolean과 정제된 오류 코드만 기록합니다.

실패한 경우 `Safe error code`와 실패한 단계만 이슈에 첨부하세요. runner의 원시 임시 파일은 작업 종료와 함께 폐기됩니다.

## 이 시험이 대신하지 않는 것

GitHub runner에는 일부 개발 도구가 미리 설치되어 있으므로 완전히 새로 설치한 일반 사용자 PC와 같지는 않습니다. 버튼 클릭, UAC, 재부팅, 설치 재개와 복구 같은 GUI 흐름은 깨끗한 체크포인트가 있는 별도 Hyper-V Windows VM에서 시험합니다. 이 프로젝트는 Hyper-V를 자동 활성화하거나 VM을 만들지 않습니다.
