# Contributing

작은 변경도 보안 경계를 넓힐 수 있으므로 다음 원칙을 지켜주세요.

1. 시스템을 바꾸는 기능은 먼저 읽기 전용 계획을 제공해야 합니다.
2. 원격 URL, 프로세스 인수, 파일 경로는 문자열 연결보다 구조화된 검증을 사용합니다.
3. API 키, 토큰, 사용자 경로 또는 실제 설정 파일을 테스트 픽스처에 넣지 않습니다.
4. PowerShell 5.1과 PowerShell 7에서 CLI 테스트와 STA GUI 테스트를 실행합니다.
5. 보안 기본값을 완화하는 변경은 위협 모델과 대안을 PR에 설명합니다.

```powershell
./tests/Run-Tests.ps1
powershell.exe -NoLogo -NoProfile -Sta -File ./tests/Run-GuiTests.ps1
./OpenClawEasySetup.ps1 -Action Diagnose
./OpenClawEasySetup.ps1 -Action Plan
```

설치 테스트는 일상 개발 PC보다 폐기 가능한 Windows VM에서 수행하세요.
