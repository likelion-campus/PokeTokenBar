PokeTokenBar 윈도우 연결 점검 (실험용)

이 폴더는 "윈도우 PC와 맥이 사무실 와이파이에서 서로 찾고 연결되는지"를 확인하는 실험용 프로그램입니다.
앱이 아니고, 아무것도 설치하지 않습니다. 끝나면 폴더를 지우면 됩니다.

준비
- 윈도우 10(22H2) 또는 11, 64비트 PC. 맥과 같은 사무실 와이파이에 연결.
- 관리자 계정이 아닌 평소 쓰는 일반 계정으로 로그인한 상태에서 실행해 주세요.
- 이 폴더 전체를 PC의 아무 곳(예: 바탕 화면)에 풉니다.
- 폴더에서 주소창에 cmd 를 입력해 명령 프롬프트를 엽니다.
- 실행할 때 "Windows의 PC 보호" 창이 뜨면 "추가 정보 → 실행"을 누릅니다(서명이 없는 실험 파일이라 뜹니다).
- "Windows 방화벽" 창이 뜨면 "개인 네트워크"에 체크하고 "액세스 허용"을 누릅니다. 이때 관리자 암호를 요구하는지
  꼭 알려 주세요.

아래 TEST1234 자리는 아무 글자나 됩니다. 맥과 윈도우에서 같은 글자를 쓰기만 하면 됩니다.

실험 A — 윈도우가 기다리고, 맥이 찾아온다
  윈도우:  ptbprobe.exe serve TEST1234
  맥:      swift scripts/team-probe.swift browse TEST1234
  기대: 윈도우 창에 ADVERTISED, TCP OK, TLS OK, FRAME OK 가 차례로 나옵니다.

실험 B — 맥이 기다리고, 윈도우가 찾아간다
  맥:      swift scripts/team-probe.swift serve TEST1234
  윈도우:  ptbprobe.exe browse TEST1234
  기대: 윈도우 창에 FOUND, RESOLVED, TCP OK, TLS OK, FRAME OK 가 나옵니다.
  참고: 사무실의 다른 팀원 앱도 FOUND 로 보이고, 그쪽은 "FAIL TLS" 로 끝납니다(팀 코드가 달라서 정상).
        맥 쪽에도 "bad MAC" 줄이 여러 개 나올 수 있습니다. 같은 이유로 정상입니다.

실험 C — 실제 앱이 보이는지
  맥에서 PokeTokenBar 앱을 켜고 팀에 들어가 있는 상태에서,
  윈도우:  ptbprobe.exe browse TEST1234
  기대: FOUND 줄에 맥 앱이 나옵니다(TLS 는 실패해도 됩니다. 코드가 다르니까요).

실험 D — 그림 그리기 (와이파이와 무관)
  윈도우:  ptbdraw.exe res out.png --hardware
  기대: "saved out.png" 가 나오고, out.png 를 열면 ci-reference.png 와 같은 그림이 보입니다.

보내 주실 것
- 실험 A, B, C 에서 윈도우 창에 찍힌 줄 전체(복사해서 붙여넣기).
- 방화벽 창이 떴는지, 관리자 암호를 요구했는지.
- out.png 파일.
- 안 되는 경우: 회사 보안 프로그램(백신, VPN 등)이 켜져 있었는지.

찾기(FOUND)가 안 될 때 추가로 해 볼 것
  맥에서 serve 를 실행하면 "port 12345" 처럼 포트가 찍힙니다. 맥의 IP 주소(시스템 설정 → Wi-Fi → 세부사항)와 함께:
  윈도우:  ptbprobe.exe browse TEST1234 --host 맥IP --port 포트번호
  이것이 되면 "연결은 되는데 찾기만 막힌 것"입니다.
