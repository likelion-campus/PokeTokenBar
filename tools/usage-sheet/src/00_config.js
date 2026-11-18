// Constants. Module-level names are top-level `var`/`function` only (see test/harness.js).

// Public by design: it only turns away passing scanners.
var SHARED_TOKEN = "996c41db62671eaf62a86cf3e18202ee";

var MAX_BODY_BYTES = 262144;
var MAX_DAYS = 62;
var MAX_TOOLS_PER_DAY = 32;
var MAX_LIMITS = 16;

var TAB_RAW = "원본";
var TAB_LIMITS = "한도";
var TAB_PEOPLE = "사람";
var TAB_DEPTS = "부서";
var TAB_TEAMLABELS = "팀이름";
var TAB_DEVICES = "기기";
var TAB_SETTINGS = "설정";
var TAB_PLAN = "플랜";
var TAB_ENT_RAW = "엔터프라이즈 원본";
var TAB_ENT_PEOPLE = "엔터프라이즈 사람";
var TAB_ENT_LOG = "엔터프라이즈기록";

var COLS_RAW = ["memberId", "닉네임", "날짜", "도구", "팀ID", "입력", "출력", "캐시쓰기", "캐시읽기", "합계", "앱버전", "플랫폼", "받은시각"];
var COLS_LIMITS = ["계정", "도구", "리셋시각", "memberId", "팀ID", "플랜", "이메일도메인", "최고사용률", "마지막사용률", "마지막읽은시각"];
var COLS_PEOPLE = ["memberId", "닉네임", "마지막받은시각", "합칠대상", "앱버전", "플랫폼"];
var COLS_DEPTS = ["팀ID", "부서이름", "참고팀이름", "처음본날"];
var COLS_TEAMLABELS = ["팀ID", "memberId", "팀이름", "마지막받은시각"];
var COLS_DEVICES = ["memberId", "비밀값해시", "처음본시각", "마지막본시각"];
var COLS_SETTINGS = ["키", "값", "설명"];
var COLS_ENT_RAW = ["날짜", "userId", "이메일", "채팅메시지", "대화", "Cowork메시지", "ClaudeCode세션", "받은시각"];
var COLS_ENT_PEOPLE = ["userId", "이메일", "부서", "처음본날"];
var COLS_ENT_LOG = ["날짜", "불러온시각", "행수"];

var ENT_API_URL = "https://api.anthropic.com/v1/organizations/analytics/users";
var ENT_API_VERSION = "2026-10-21";
var ENT_FIRST_DATE = "2026-01-01";
var ENT_PAGE_LIMIT = 1000;
var ENT_MAX_REQUESTS = 100;
var ENT_TIME_BUDGET_MS = 150000;   // stop sending requests after this long, so writing and rendering fit the 6 min run
var ENT_SLEEP_MS = 1000;
var ENT_RECENT_DAYS = 3;
var ENT_KEY_PROP = "enterprise_api_key";        // UserProperties
var ENT_STATUS_PROP = "enterprise_status";      // DocumentProperties, JSON

var DEFAULT_SETTINGS = [
  { key: "forecast_short_pct", value: 100, note: "리셋 때 예상이 이 % 이상이면 \"모자람\"." },
  { key: "forecast_fit_pct", value: 70, note: "이 % 이상이면 \"알맞음\", 아래는 \"남음\"." },
  { key: "full_week_pct", value: 100, note: "주간 최고 사용률이 이 % 이상이면 \"다 쓴 주\"." },
  { key: "suggest_weeks", value: 4, note: "제안에 쓰는 끝난 주간 창 수." },
  { key: "suggest_up_full_weeks", value: 2, note: "그중 다 쓴 주가 이 수 이상이면 \"올리기 검토\"." },
  { key: "suggest_down_max_pct", value: 40, note: "모든 주의 최고 사용률이 이 % 미만이면 \"내리기 검토\"." },
  { key: "min_pace", value: 0.1, note: "창이 이 비율만큼 지나기 전에는 예상을 내지 않음." },
  { key: "stale_hours", value: 24, note: "이보다 오래된 한도 값으로는 예상을 내지 않음." },
  { key: "plan_order_claude", value: "Pro, Max, Ultra", note: "아래에서 위로 플랜 순서." },
  { key: "plan_order_codex", value: "plus, pro", note: "아래에서 위로 플랜 순서." }
];

var DASHBOARD_TABS = [
  { name: "이번 달", kind: "thisMonth" },
  { name: "지난 7일", kind: "last7" },
  { name: "지난달", kind: "lastMonth" }
];
