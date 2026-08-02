# Architecture

## 목표

OpenClaw Easy Setup은 초보자용 화면과 실제 시스템 변경 코드를 분리합니다. 현재 PowerShell MVP는 향후 데스크톱 GUI에서도 재사용할 수 있는 설치 엔진 역할을 합니다.

```text
사용자 CLI / 향후 GUI
        |
        v
진단·계획 계층 (기본 읽기 전용)
        |
        v
승인 경계 (-Apply + ShouldProcess)
        |
        v
다운로드 → 무결성 정보 → 공식 설치 → 온보딩 → 검증
```

## 구성요소

- `OpenClawEasySetup.ps1`: 초보자용 진입점과 동작 선택
- `src/OpenClawEasySetup.psm1`: 상태 진단, 출처 검증, 설치, 온보딩, 검증
- `config/openclaw-source.json`: 코드와 분리된 공식 출처·요구사항
- `locales/ko-KR.json`: Windows PowerShell 5.1에서도 안전하게 읽는 UTF-8 한국어 메시지
- `tests/Run-Tests.ps1`: Pester 설치 없이 실행되는 결정적 단위·스모크 테스트

## 설계 결정

### PowerShell-first

첫 단계는 별도 앱 런타임을 설치하기 전에 Windows 기본 환경에서 진단할 수 있어야 합니다. GUI는 안정화된 함수 인터페이스 위에 추가합니다.

### 읽기와 쓰기의 분리

`Diagnose`, `Plan`, 기본 `Install`은 시스템을 바꾸지 않습니다. 실제 설치에는 `-Apply`가 필요하고 PowerShell `ShouldProcess`가 다시 확인합니다.

### 원격 파이프 실행 금지

`Invoke-WebRequest ... | Invoke-Expression` 형태를 사용하지 않습니다. 특정 릴리스와 커밋의 스크립트를 먼저 파일로 받고 출처·리디렉션·크기·문법·고정 SHA-256을 검사한 뒤, 고정 인수와 정리된 환경을 사용하는 별도 PowerShell 프로세스에서 실행합니다.

### OpenClaw 설정 직접 수정 보류

초기 MVP는 빠르게 변할 수 있는 OpenClaw 설정 파일을 임의로 쓰지 않고 공식 온보딩을 호출합니다. 안전한 기본 설정 생성은 공식 스키마 조회와 마이그레이션 테스트가 준비된 뒤 추가합니다.

## 신뢰 경계

- 이 도구의 저장소와 릴리스
- `config/openclaw-source.json`에 승인된 공식 다운로드 호스트
- 다운로드된 설치 파일
- OpenClaw Gateway 및 사용자가 연결한 모델·메신저

각 경계에서는 문자열 기반 신뢰 대신 HTTPS 제한, 해시, 서명 상태, 명시적 승인, 최소 권한, 사후 보안 감사를 조합합니다.
