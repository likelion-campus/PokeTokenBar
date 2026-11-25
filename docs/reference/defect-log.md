---
summary: "결함 대응 프로토콜로 축적된 구체 규칙 — 한 번 겪은 부류의 실수를 다시 겪지 않기 위한 원장."
read_when:
  - 결함·회귀·공백을 고치는 중 (프로토콜 4단계의 '부류 스윕'·'영구 캡처' 근거)
  - 동시성/await·옵셔널 판정·캐시 무효화·외부 로그 포맷을 건드릴 때
  - 크기 상한이 없는 사용자 파일을 읽는 코드(사용량 로그 파서)의 메모리를 손볼 때
  - 메뉴바·플로팅 펫 등 상시 표시 애니메이션의 성능을 손볼 때
  - 스프라이트·이미지를 고정 크기 프레임에 그릴 때(비율 왜곡 부류)
  - 세이브 이전/병합·외부 파일 입력 경로를 만들 때
  - 윈도우 공용 집합(`mac-only.txt`)·`Platform/`·윈도우 CI 테스트를 건드릴 때
  - 팀 프레임을 받거나 저장하는 코드, 다른 Mac이 고른 값을 쓰는 코드를 손볼 때
---

# 결함 대응 축적 규칙

`CLAUDE.md` §결함 대응 프로토콜의 4단계(근본원인 → 부류 스윕 → 회귀 테스트 → 영구 캡처)를 거쳐
남은 규칙들이다. 각 항목은 실제로 확인한 결함·회귀·표시 공백에 묶여 있다.

## 스프라이트 전환

- **A transient GIF request failure must not become a permanent static state.** `SpriteView` used
  one `.task(id:)` request, showed its PNG fallback, then returned; neither a later cache fill nor
  network recovery changed the task ID. The menu had the same class of defect: nonempty bob
  frames satisfied its loaded-key gate after a failed GIF request. This is a confirmed recovery
  gap, not proof of the cause of the reported floating-pet freeze. Both surfaces now await the
  same cancellable recovery loader, apply a static fallback once, and retry at 2/4/8/16/30-second
  intervals. The 30-second ceiling limits request frequency during long outages, not the number
  of attempts; unsupported species remain static without retrying. The menu owns one load task
  so a late PNG cannot replace a successful GIF, cancels it on subject change/display sleep, and
  retries unfinished loads on wake. Sleep clears unfinished fallback frames rather than resetting
  only the key: graduation can select the nil-key egg while asleep, which would otherwise match
  the invalidated key and reuse the previous Pokémon's nonempty fallback. Successful GIFs stay cached.
  Existing preview tests sampled only the cached first frame
  and helper tests checked identities, so neither exercised a failed first request. Permanent
  guards: `SpriteAnimationRecoveryTests` drive the production recovery/URLSession/cache/decoder
  path with isolated fixtures, including fail-once recovery, another surface's later cache fill,
  bounded backoff, cancellation during sleep/shiny download, unsupported species, and warm form
  caches. These tests are headless; they do not establish ongoing on-screen SwiftUI rendering.

- **움직이는 상세 화면은 첫 렌더부터 캐시된 GIF 프레임을 사용한다.** 정적 PNG는 96px 투명
  캔버스이고 GIF는 본체에 맞춘 작은 캔버스라, PNG를 먼저 보여준 뒤 같은 슬롯에 GIF를 맞추면
  정지한 작은 포켓몬이 뒤늦게 커진다. 디코드 프레임을 캐시해 시드와 재생에서 공유하고 GIF 요청을
  정적 PNG 다운로드 뒤에 직렬화하지 않는다. 미캐시 정적 폴백만 콘텐츠 크롭하고 원본 PNG 상태는
  보존해 정적 보기로 전환할 때 복원한다. `SpriteAnimationPreviewTests`는 실제 SwiftUI 첫 렌더의
  GIF 픽셀·크기, 캐시 재사용, 프레임 지연, 정적 원본 보존을 검사한다.

- **재시도를 한 경로에만 두면 나머지 경로가 같은 결함으로 남는다.** 광장은 팀원 그림만 30초 뒤 다시 받아서, 창을 열
  때 요청이 실패하면 내 포켓몬은 다시 열 때까지 회색 원이었다. 뒷모습 실패는 앞모습으로 대체되고 `isPlaceholder`가
  false라 내 것도 팀원 것도 재시도가 없었다. **왜 못 걸렀나:** 재시도 테스트가 팀원 경로와 앞뒤 모두 실패한 경우만
  밟았다. 뒷모습은 원래 없는 그림일 수 있고 `SpriteStore`는 404와 오프라인을 구분하지 않으므로 `backRetryLimit`번만
  다시 묻는다. 가드: `testFailedOwnSpriteIsRequestedAgainWhileOpen`·`testOwnSpriteRetryIsDroppedByANewerLoadOrAClose`·
  `testMissingBackIsRequestedOnlyAFewTimes`·`testMemberBackThatFailedOnceIsRecovered`. 스윕에서 남은 것: 목록과 카드의
  `PlazaIconLoader` 아이콘은 `.task(id:)` 한 번뿐이라 실패하면 다시 마운트될 때까지 빈칸이다.

## 판정·데이터

- **Provider opt-out must also cover independently added official limits.** The provider toggle
  and the OpenCode Go/Grok limit integrations passed separately, but their combined refresh
  pipeline still fetched both disabled providers and retained their previous limits and expired-login
  notices. The toggle tests covered only the previously existing limit providers, while the new
  limit tests exercised enabled providers only. Guard every provider-specific limit refresh with
  `isProviderEnabled` and clear its status and auth notice, matching Cursor and Antigravity.
  The class sweep covered Claude (primary/additional), Codex, Cursor, Antigravity, OpenCode Go and
  Grok. Four regression cases cover disabled-at-start with zero fetches and disabling after a
  loaded status followed by HTTP 401. All four fail without the new guards (10 assertions), so the
  tests detect both unwanted external fetches and state left behind by a disabled provider.

- **Legacy save imports must initialize completion history before tracking new catches.**
  Generation-dex completion seeding originally ran only after `load()` in the initializer.
  `applySave` replaced that seeded state with an older save whose missing tracking fields
  decoded to `dexCompletionsSeeded = false`; every later completion check then returned early.
  Restarting silently seeded completions earned in that session, so their notifications were
  lost permanently. Seed immediately after importing and migrating profiles, before saving:
  existing badges become history without notifications and later catches can announce new
  badges. The class sweep covered all state replacements: startup loads already seed, while
  snapshot restoration delegates to `applySave` and needs the same repair. Earlier tests only
  loaded legacy files at startup and missed the import boundary. Permanent guards
  `testLegacyImportSeedsExistingCompletionsBeforeANewHatch` and
  `testLegacyImportWithoutEarnedBadgesStillEnablesFutureCompletions` decode actual old-format
  save envelopes, import them, verify persisted seeding (including no earned badges), then
  hatch the final Johto species and require the new notification key in the same session.
  Both tests failed before the fix with seven assertions and pass after adding import seeding.

- **Cursor usage and limits must share the refreshed login, with cookie and Bearer forms kept
  distinct.** Usage reread the expired SQLite access token on every poll while limits refreshed
  only its private local variable. This left limits working beside frozen/cached usage. A browser
  `CURSOR_SESSION_TOKEN` cookie also became an invalid `Bearer user::jwt` in the limits request.
  The old HTTP test copied the request into `TestCursorLimitsProvider`, bypassing the production
  credential selection and refresh branches. `CursorAuthentication` now pairs access/refresh from
  one selected database root, shares refreshed credentials in memory, and normalizes raw or
  percent-encoded browser cookies for Bearer requests. Explicit overrides never refresh a local
  account. Root/access/refresh/override/logout changes discard refreshed state; a rotated refresh
  token survives transient grants in memory without rewriting Cursor's database. Both fetchers
  retry only 401/403 once, retaining existing non-auth failure/cache semantics. The class sweep
  covered both Cursor callers, Stable/Nightly/custom roots, grant ownership and the live-network
  gate. Two production-path synthetic reproducers failed before the fix (usage remained on the
  old token after a successful limits refresh; limits sent the entire cookie as Bearer).
  The initial 13 production regression tests passed; the final 15 `CursorAuthenticationTests`
  cover recovery in both call orders, cookie encodings, account/root
  invalidation, local-root pairing, override isolation, grant failure/retry/rotation, bounded
  retries and the live grant gate. `CursorLimitsTests` now calls the real provider.

- **A model-price test needs an independent bucket-level oracle.** Sonnet 5.5 copied Sonnet 5's
  cache-read rate ($0.20/MTok) although its official rate is $0.10; source-unpriced Claude logs
  therefore doubled that bucket's estimate. The standard-row test repeated the wrong literal,
  and model coverage only required a positive estimate. Check each newly introduced model row
  and long-context rule against primary pricing, then exercise real-format JSONL through
  `LocalUsageCache` and aggregation. `testSonnet55ClaudeLogPricesColdWarmAndPersistedTokenCaches`
  independently prices input/output/cache-write/cache-read = 100/10/40/1000 as 1,150 tokens and
  $0.0005; old code returns $0.0006000000000000001 and fails all five cold aggregation assertions.
  Fixed cold, warm and persisted-cache paths pass; `ModelPricingTests` has 12 tests and
  `UsageCostTests` 13 (one skipped), zero failures. The class sweep confirmed Claude disk blobs
  persist raw token/model entries, not estimated money: do not bump the parser version or discard
  caches for this price-only change. Keep explicit source cost, including zero, authoritative.

- **Snapshot summaries must carry the current individual's species-resolved form.** Saved Sky
  Shaymin restored correctly but Settings listed its thumbnail as Land: `SaveSnapshot` retained
  species/shiny metadata without a form, and the row omitted `SpriteView.form`. Correct payload
  and restore checks did not cover this derived-summary-to-view boundary. Derive `currentForm`
  for the active current species in create, envelope listing and raw legacy listing, then forward
  it to the sprite; do not copy a future evolution's carried form. The list model is non-Codable,
  so no schema bump, payload rewrite or restore change is needed. Sweep all three constructors
  and preserve `displaysShiny` for disguised Ditto. Guards:
  `testSnapshotKeepsNonDefaultFormInSummaryAndRestoredState` and
  `testSnapshotSummariesResolveCurrentAppearanceAcrossLegacyAndEnvelopeFiles`, including missing/
  invalid forms, legacy Unown, precursor/single-appearance species and eggs. Restoring old summary
  behavior fails both tests with 16 assertions; the fixed `SaveSnapshotTests` passes all 11 tests.
  Non-A Unown already had this display gap; generic forms widened it, without corrupting saves.

- **Temporary refresh failure must retain the credential needed for the next automatic retry.**
  An expired Keychain-only Antigravity credential fell back to its expired access token after a
  grant timeout/429/5xx. Quota401 invalidation then deleted the only cached refresh token, and
  automatic polls could not reopen Keychain. This recovery gap already existed in v2.5.5; it is
  not a newly broken working path. Tests covered successful grants and permanent invalid_grant,
  not transient failure followed by another automatic poll. Cache the acquired credential before
  awaiting the grant; throw temporary errors before sending expired access, classify 429/5xx,
  and preserve valid-token fallback and permanent-error behavior. Sweep provider-specific grant
  ownership rather than copying this policy to Claude/Cursor. Four new recovery tests (timeout,
  503, 429 and initial manual timeout) all fail against old behavior; all 21 fixed
  `CredentialSwitchCacheTests` pass, including valid-token manual fallback, with no automatic
  Keychain reread. These use production token/cache transport with synthetic credentials; the
  quota401-to-invalidate transition is modeled, not a live provider or Keychain verification.

- **Appearance-only forms need an explicit default-data note at both metadata presentations.**
  Home and Pokédex showed an alternate-form name/sprite beside default-form metadata without
  explaining the difference. Existing appearance/collection checks did not test that disclosure;
  the intended species-based API/cache/profile contract itself was not a failed form lookup.
  Keep that contract: do not expand this fix into per-form API data or profile regeneration.
  Show `L.defaultFormDataNote` only for loaded details and a non-default displayed form, using
  Home's current species and the Pokédex's displayed selection/representative, not its aggregate
  input. Sweep both call sites, normalized nil/invalid/foreign forms, eggs, unavailable details
  and all eight localization columns. The two production-view native tests
  `testHomeExplainsLoadedAlternateMetadataOnly` and
  `testDexExplainsTheDisplayedFormRatherThanTheOriginalSelection` pass and cover initial Home
  and Pokédex presentations. Keep mounted picker transitions and localized layout checks
  separate from these initial-render guards.

- **An idle day must not erase historical usage.** The store admitted enrichment-only snapshots
  only for a positive active block, so providers with no usage today lost their week/month totals
  and chart. Earlier tests deliberately rejected even positive historical totals to hide unused
  provider tabs; that conflated "unused today" with "no recorded usage". Keep snapshots when a
  block, period, or daily series has positive tokens, while excluding non-nil all-zero summaries.
  `UsageStoreTests` covers each history source independently, nil today/nil block, repeated
  refresh, enrichment failure, successful empty replacement, and ledger recording. The source
  sweep found this carrier gate was the shared loss point; today-based burn/limit eligibility
  remains intentionally scoped to current activity. Preserve carriers during phase 1 to avoid
  hiding the chart between refresh phases. Removing the history predicates makes the historical
  carrier regression fail; restoring them passes all three history regression tests.
- **Calendar totals are not a "recently used" signal.** Week and month totals reset at their
  boundaries, so a provider used Friday had week = month = 0 on Monday (or after the 1st) and lost
  its tab — and with it the official limits, which the popover can only reach through a snapshot,
  although the limits had been fetched successfully (#336). Why it was missed: every carrier test
  used positive week/month fixtures, so none crossed a boundary. Snapshots now also stay when the
  newest positive-token entry (`lastUsage`, from the shared `ProviderEnrichment.local`) is within
  `LocalUsageReader.recentUseWindow` (7 days, the weekly quota window); zero-token synthetic
  records do not count (#56 boundary). `enrichmentScanStart` covers that window, and snapshots
  keep provider registration order because carriers arrive in task-completion order. Guards:
  `testCarrierForProviderUsedWithinRecentWindowAcrossCalendarBoundaries`,
  `testNoCarrierForProviderIdleBeyondRecentWindow`, `testSnapshotOrderFollowsProviderRegistrationOrder`,
  `testEnrichmentLastUsageIgnoresZeroTokenEntries`, extended `testEnrichmentScanStartCoversAllWindows`.

- **Species ownership is not an individual's appearance.** A species-level shiny flag means
  at least one shiny was collected; using it for the selected individual's badge mislabeled
  normal catches, and earlier evolution pages offered no way to choose their normal appearance.
  Track normal and shiny ownership separately, let detail pages select an owned appearance,
  and keep the selected profile, sprite, and badge consistent. Catch-log rows must always use
  their own persisted color. Existing tests checked aggregate ownership and reload predicates,
  while the catch-log rendering fixture contained only normal individuals; they did not exercise
  mixed-color records together. Cover both acquisition orders and native rendering with distinct
  synthetic sprite colors, without modifying user saves or bundling third-party artwork.
  Native appearance tests must wait for the expected rendered sprite with a bounded deadline,
  then assert both expected pixels and absence of the previous color. A fixed 100ms sleep passed
  locally but sampled the previous sprite in macOS 15 CI: the header had updated while the
  sprite's independent SwiftUI `.task(id:)` had not finished rendering. Keep transition-index
  diagnostics and prove a permanently stale sprite still fails after the readiness deadline.
  Similarly, Pokédex grid cells previously gated shiny sprite rendering on `isSelected` (from
  an older design where tapping toggled selection in place); once tapping opened the detail
  sheet, cells were never selected in place and shiny species always rendered with normal sprites.
  `DexSpeciesCell` must render shiny sprites directly for collected shiny species, verified
  by `DexColorRenderingTests.testPokedexGridRendersShinySpeciesColor`.

- **Bundled CLI discovery must cover the shipped app layout.** ChatGPT moved Codex from
  `Contents/Resources/codex` into `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex`.
  After an update removed the cached executable, GUI discovery returned nil and hid the limits.
  Fake-response tests bypassed the production candidate list. `CodexRateLimitsProviderTests`
  now checks both bundle layouts in the default candidates and preserves dedicated-install
  precedence; removing the new candidate must fail the regression. The source sweep found
  this provider is the only owner of ChatGPT CLI bundle paths.

- **Localized metadata names must not replace persistent API identifiers.** The dex rendered
  ability, move, and type slugs directly, while existing tests covered species names and profile
  metadata rather than these visible labels. All five detail-view name sites now use a shared
  selected-language → English resolver, with a formatted identifier only after a completed response or failed request.
  Pending metadata must show a neutral placeholder, not an English identifier that flashes before
  translation. Keep a synchronous presentation snapshot for the first frame on detail reentry;
  the API client remains responsible for freshness. Test pending, loaded, partial, and failed
  states separately—the old test incorrectly asserted English during loading.
  Preserve every API language in the cache, normalize legacy language-code casing, and derive
  supported API codes from `AppLanguage` so future languages need no second allowlist.
  Fetch names from mounted detail rows rather than profile preparation. `PokemonNameLocalizationTests`
  covers locale selection, missing translations, future languages, native text rendering, request
  reuse, disk restoration, and offline retry without changing profile identifiers.
  Existing saves need a name-cache version as well: nonempty dictionaries from the old allowlist
  are not complete multilingual responses. `DexNameMigrationTests` covers legacy JSON, duplicate
  catches, offline/partial recovery, progress preservation, and an unavailable language that must
  not trigger repeated fetches. Restoring the old nil-only backfill filter makes the regression fail.
  Catch-log rows must resolve legacy entries even when old names exist, and prefer persisted
  multilingual names over previously rendered strings after a language change.

- **Translate at display time, including errors and accessibility labels.** Storing translated
  error strings left session-key and quota-refresh failures in the previous language. Store the
  failure and resolve it through the shared language selector. `LocalizationErrorsTests` switches
  languages while a real store error remains visible and checks diagnostic preservation.
  English UI literals bypassed the Hangul-only source guard; `LanguageSurfaceRegressionTests`
  now covers usage labels, hidden control labels, selected-language backup dates, and Gen-V
  `light-ball-egg`/`form-change` methods alongside native rendering in all supported languages.

- **Balance numbers in copy come from the runtime value, never a literal.** The shiny hatch
  notification said "(1/64)" in every language after the Shiny Charm made the real odds 1/48, and
  the first-run egg hint kept "~5M tokens" after the growth slider could move the hatch point
  (fixed separately).
  The copy was written before the modifiers existed, and `LocalizationInterpolationTests` only
  checks that placeholders survive, so a number with no placeholder was never compared with the
  value the game uses. Pass the value the logic uses (`CompanionStore.shinyDenominator`, the
  difficulty-scaled threshold) into the string. When a message describes an earlier roll whose
  inputs are not saved, such as a Ditto reveal after hatch, leave the number out rather than guess.
  When adding a modifier (charm, difficulty, boost), grep `Localization.swift` for the constants
  it changes. `ShinyCharmTests` checks the notification odds with and without the charm.

- **Cost availability is not a numeric zero.** Codex providers overwrote priced totals with zero
  while leaving cost UI enabled; earlier tests asserted that subscription policy instead of
  comparing the public provider result with priced log entries. Preserve explicit source zero,
  unknown model/token breakdown, and source/estimate provenance separately through daily, period,
  block, and merged chart totals. An unknown portion must mark a total partial, never complete.
  `UsageCostTests` exercises Codex JSONL through cold/warm cache and the provider, source-zero vs
  missing, mixed totals, menu/chart projections, legacy decoding, and native localized rendering.
  The Codex regression must fail if its provider again overwrites the returned cost with zero.
  Session/turn aggregates (Hermes/Aside), Cursor bubbles without cache buckets, and Kiro text
  estimates cannot be passed to request-size-dependent pricing as if they were single requests.
  Parser semantic changes require the corresponding disk-cache version bump.

- **Incremental transcript parsing must retain cumulative ledgers, not add their totals.** Claude's
  latest `cost-state` reprices the entire session, including entries cached before the appended tail.
  Keep raw entries and the latest ledger together in the blob, then attribute costs after merging.
  Retain that ledger when the next tail has none; discard it on a full reparse. Assistant-only append
  tests miss this semantic conflict with source-cost attribution. `ClaudeReportedCostTests` covers
  changed totals, unchanged cache hits, disk reload without a new ledger, truncation, and partial ledgers.

- **프로필 레벨은 난이도와 반복 부화 보정을 반영한 단계 진행에서 계산한다.** #244/#254의 임계값을
  낮춰도 #264가 원시 토큰을 기본 졸업 비용으로 나누면 졸업한 개체가 레벨 5 또는 52에 남는다.
  완료 단계의 기본 비용과 현재 단계의 실제 임계 대비 진행률을 합산해 표준 성장량을 영속한다.
  난이도 증가·가져오기는 이미 얻은 성장량과 레벨을 낮추지 않으며, 졸업 기록을 만들기 전에 100을
  확정한다. 메타몽 공개는 희귀도 간 성장 단위를 환산하고 개체 정보만 재설정한다.
  `ProfileGrowthIntegrationTests`는 난이도 양 끝·반복 부화·설정 변경·재시작·가져오기·사탕·오프라인을 검증한다.

- **옵셔널 tautology.** 옵셔널 필드라도 *생산자가 항상 채우면* `x != nil` 은 항상 참이다. "값이 있나"는
  의미값으로 검사한다(예: `totalTokens > 0`, 또는 진짜 nil 가능한 필드 `activeBlock`). — weekTotal 회귀(#56).
- **사용량 엔트리의 존재는 실제 사용의 증거가 아니다.** Claude 는 로컬 세션 시작 과정에서 토큰 필드가
  전부 0인 `<synthetic>` assistant 엔트리를 기록할 수 있다. `activeBlock` 이 최근 엔트리 존재만 검사하고,
  store 가 non-nil 블록만 검사하면 오늘 사용량 0인 Claude Code 탭이 생긴다. 블록 집계와 캐리어 스냅샷
  경계 모두 `totalTokens > 0`을 요구한다. 회귀는 비어 있는 배열이 아니라 **non-empty zero-token 입력**으로
  `LocalUsageReaderTests.testActiveBlockIgnoresZeroTokenSyntheticEntries`와
  `UsageStoreTests.testNoCarrierForZeroTokenActiveBlock`에서 고정한다.
- **JSON `null` 은 "값 있음"이 아니다.** `obj["x"] != nil` 은 `NSNull` 에도 참이라 `intValue` 가 0 을 돌려주고,
  그 0 으로 캐시분을 빼면 토큰이 통째로 사라진다. 숫자 필드는 `NSNull`·문자열·부재를 모두 nil 로 만드는
  추출기(`intOrNil`/`doubleOrNil`)로 읽고, 대체 스펠링 폴백은 그 nil 로 판단한다.
  **숫자만의 문제가 아니다** — 존재 판정에도 같은 함정이 있다. `json["claudeAiOauth"] == nil` 로 계정 OAuth
  유무를 보면 `"claudeAiOauth": null`(로그아웃 상태)이 "있음"으로 판정돼 재로그인 안내 대신 엉뚱한 메시지가
  나간다. 기대 타입으로 캐스팅되는지로 판단한다(`(json["x"] as? [String: Any]) == nil`). 회귀 가드는
  부재·`null`·정상 셋을 모두 넣어야 한다 — 부재와 정상만 넣으면 통과하면서 `null` 을 못 잡는다.
- **관대 디코딩(`lenient`/`Lossy`)을 유지하려면 신뢰경계의 값 범위 검증이 짝으로 와야 한다.** 관대 디코딩은
  "한 필드가 깨져도 도감을 안 날린다"를 얻는 대신 "말이 안 되는 값도 통과시킨다"를 떠안는다. 자기 앱이 쓴
  파일만 읽을 땐 무해하지만, **외부 파일을 읽는 경로가 생기는 순간 그 트레이드오프가 라이브가 된다** —
  `Int.max` 같은 값이 그대로 저장되면 이후 산술이 Swift 오버플로 트랩으로 프로세스를 죽이고, 재기동해도
  같은 파일을 읽어 다시 죽는다(`load()` 의 `.corrupt` 복구는 디코드가 *성공*하므로 발동 안 함 → 파일을
  손으로 지우기 전까지 앱 사용 불가). 방어는 다운스트림 산술 지점마다가 아니라 **값이 들어오는 경계 한
  곳**에서(`SaveTransfer.sanitized`). 자르는 대상은 산술에 쓰이는 수치뿐 — 도감·인벤토리 *항목*은 잘라내면
  데이터 손실이다. (딥리뷰 2026-08-03: SIGTRAP 재현.)
- **부화 시 확정되는 개체별 성장 보정은 활성 개체에 영속하고 임계값 소비 경로를 하나로 모은다.** 반복 base의
  가중치는 `chooseBase` 에서만 낮췄고 성장 비용은 희귀도·형태·단계만 읽어서, 이미 졸업한 선형 라인을 다시
  부화해도 새 라인과 같은 총비용을 냈다(#253). 기존 테스트도 전역 밸런스 합계와 첫 부화만 검증해
  `졸업 → 같은 base 재부화` 트리거를 밟지 않았다. 할인 자격은 planned final이 아니라
  `collectedFinals` 의 **base predicate**로 hatch 순간 결정한다 — final 기준이면 아직 공개하지 않은 분기 선택이
  남은 토큰으로 샌다. 결과는 `MonState.hasGrowthBoost` 에 저장하고 Home 표시·일반 성장·메타몽 리빌이 모두
  `stageThreshold(for:)` 에서 `MonState.phaseThreshold` 에 난이도를 곱한 값을 읽는다.
  #244/#254 통합 시 한쪽 임계값만 선택하면 다른 배율이 사라진다. 기존 테스트는 두 기능을 따로 검증했다.
  `testRepeatBoostComposesWithDifficultyAndLiveChanges` 는 실제 졸업·재부화 후 두 배율을 합성하고,
  표시 임계 직전/도달·설정 즉시 변경·최종 졸업까지 검증한다.
  가드: `testRepeatGrowthIsDecidedFromTheCollectedBaseNotThePlannedFinal`·
  `testRepeatGrowthPersistsAcrossRestartWhileLegacyActiveDefaultsToStandardGrowth`·
  `testRoundTripPreservesActiveRepeatGrowthBoost`·`testBoostedDisguiseRevealsAtTheHalvedThresholdAndANewDittoDropsTheBoost`.
  메타몽 리빌은 hatch 뒤에 개체의 base 가 바뀌는 유일한 지점이라 base predicate 를 **리빌 때 메타몽 base 로
  다시 판정**한다. 위장체의 할인은 위장 라인 기준(정체를 숨긴다)이고, 리빌이 그 값을 그대로 넘겨서 이미
  졸업한 메타몽을 다시 얻어도 x2 가 없고 새 메타몽이 위장 라인의 x2 를 가져갔다. 리빌 테스트가 모두
  `collectedFinals: []` 로 시드해 `메타몽 졸업 → 위장 메타몽 재부화` 트리거를 밟지 않았다.
  가드: `testRevealingAnAlreadyGraduatedDittoGrantsTheRepeatBoost`.
- **같은 규칙이 세이브 파일이 아니라 *외부에서 오는 모든 수치*에 적용된다 — 파싱 경계도 포함.** 위 규칙을
  "세이브 파일"로 좁게 읽은 탓에 사용량 로그 파서(`LocalUsageReader`)의 `intValue` 가 무방비로 남았고,
  같은 SIGTRAP 이 Codex·Claude·Gemini 세 경로에서 재현됐다(딥리뷰 2026-08-04). 사용량 로그도 앱이 쓴 게
  아니라 **CLI 가 쓴 외부 파일**이다 — 손편집·전송 손상·업스트림 버그가 그대로 들어온다.
  방어 지점은 추출기 하나(`LocalUsageReader.intValue`/`intOrNil`)이고, **상한을 `Int.max` 로 잡으면 안 된다**:
  클램프 자체는 통과해도 `output + thoughts` 처럼 파싱 직후 더하는 곳에서 다시 트랩난다. 합산 여유가 있는
  상한(`maxParsedTokenValue`)을 쓴다. 회귀 가드는 프로바이더별로 **테스트를 쪼개라** — 트랩은 프로세스를
  끝내므로 한 테스트에 몰면 뒤 케이스가 아예 실행되지 않는다.
  **추출기가 `LocalUsageReader` 밖에 있으면 같은 함정이 그대로 남는다.** OpenCode·Cursor의
  `LocalAdditionalUsageProvider.intValue` 와 Hermes의 `columnInt` 는 `Int.max` 로 포화시킨 뒤
  `input + output` 에서 다시 SIGTRAP 했다(`testCursorHugeTokenCountsDoNotTrapOnTheAdd`·
  `testHermesHugeSessionTokensDoNotTrapOnTheReasoningAdd`). 대시보드 JSON 을 읽는
  `CursorUsageAPI.intValue` 도 같은 포화 후 `makeEntry` 합에서 트랩한다
  (`testParseCursorUsageEventClampsHugeTokenCounts`). Kiro 타임스탬프의 `Int64(Double)` 도
  `Int64.max` 를 넘는 유한값에서 트랩한다. 상한은 더하는 추출기마다 같이 건다.

- **기간 비교의 "데이터가 있는가"는 그 구간의 *가장 오래된* 날로 판정한다.** 사용량 요약이 지난주
  대비를 낼지 말지를 지난 구간의 **첫 날(=가장 최근 날)** 로 판정했더니, 원장이 구간 중간부터 시작해도
  비교가 성립했다 — 빠진 날들은 0 으로 합산돼 실측 delta 가 +200% 로 부풀었다(가드의 목적이던 "신규
  설치가 없던 주 대비 급등을 주장하는" 바로 그 증상). 누락분을 0 으로 세는 합계 위에 커버리지 게이트를
  올릴 땐, 게이트 기준점이 **합계의 모든 날을 덮는지** 확인한다(`testAHalfCoveredPreviousPeriodIsNotAComparison`).
  같은 맥락에서 손편집 가능한 `UserDefaults` 를 원장으로 쓰면 키 검증도 **길이가 아니라 파싱**으로
  한다 — `"0000-00-00"` 처럼 날짜가 아니면서 모든 실제 날짜보다 작게 정렬되는 키는 커버리지를 위조한다.
  그리고 "0 인가, 모르는가"는 행의 유무로 추론하지 말고 **커버리지 시작일을 따로 저장**한다
  (`UsageLedger.coveredSince`) — 행은 사용량이 있는 날에만 생기므로, 첫 행 날짜로 커버리지를 추정하면
  조용했던 기간과 기록 이전 기간이 구별되지 않는다. 오래된 행을 잘라낼 땐 커버리지도 함께 올린다
  (`testPruningForgetsTheCoverageItDrops`).
- **본가 공식의 종 예외 — 껍질몬(#292) HP 는 항상 1.** `PokemonStatCalculator` 는 HP 를 일반 공식
  `((2·base + iv)·level)/100 + level + 10` 으로만 계산해 껍질몬이 Lv50 에 67 HP 로 표시됐다. 토쿠닌
  (#290) 분기에서 선택될 수 있고 Gen V 상한 안이라 실제로 부화 경로에 있다.
  **왜 못 걸렀나:** 스탯 테스트는 일반 종(야돈) 하나로 공식만 확인했다. 공식의 종 예외는 그 종을 넣어야만 보인다.
  **수정:** 종 id 로 HP 1 고정(`shedinjaSpeciesID`). base HP 1 이라는 이유로 판정하지 않는다 — 공식 데이터에
  base HP 1 인 종은 껍질몬뿐이지만 규칙은 "종" 에 걸린 것이다.
  **회귀 가드:** `PokemonProfileLogicTests.testShedinjaAlwaysHasOneHP` — Lv1/50/100 모두 1, 다른 스탯은 일반 공식,
  base HP 1 인 다른 종은 일반 공식. 수정 전 3건 실패 확인.

- **그레고리력 문자열은 그레고리력으로 읽는다.** `TeamEventFactory`는 `day`를 그레고리력으로 쓰는데
  `TeamFeedStore.dayStart`는 Mac의 달력으로 읽어, 불교력·일본력 Mac에서 날짜가 수백 년 밀렸다. 소식을 보내지도 받지도
  못하고, 불교력에서는 실행할 때 저장된 소식까지 지워졌다. **왜 못 걸렀나:** 테스트 달력이 모두 그레고리력이라 쓰는
  달력과 읽는 달력이 항상 같았다. 스윕: 팀 코드에서 이 경로뿐이고, `PopoverView.daysInMonth`는 이미 그레고리력이다.
  가드: `testGregorianDayIsReadOnANonGregorianMac` — 실제 `TeamEventFactory` 출력을 비그레고리력 저장소에 넣는다.

- **피어가 보낸 문자열을 저장·재전송하려면 보내기 전에 받는 쪽에서 크기 상한을 건다.** 팀 광장 일정(`PlazaSchedule`)을
  채택할 때 `changedByName`·`changedBy`·`seasonPeriod`에 상한이 없어, ~900 KB 이름 하나가 시계 검사(+600초)를 통과해
  모두에게 저장되고 이후 **모든 presence 에 실려** 프레임 상한(1 MB)을 넘겼다. 그 팀원의 presence 가 팀 전체에서 조용히
  끊기고 재시작해도 남는다. **왜 못 걸렀나:** 일정 테스트는 값의 *시각·범위*(먼 미래, 잘못된 시간대)만 두드렸고 문자열
  *크기*는 보지 않았다. 닉네임은 `validNickname`이 막아 주지만 새 필드는 그 경로를 지나지 않았다. 규칙: 피어 입력이
  디스크에 쓰이거나 다시 퍼지면 필드마다 상한을 두고, 닉네임 성격이면 `validNickname`과 같은 규칙을 쓴다(`adoptSchedule`의
  `isBounded`). 스윕: 소식·반응(`TeamFeedStore.bounded` 64바이트 + `validNickname`), presence 닉네임(`validNickname`), 채팅
  (저장·전달 안 함, `prepared`), 그 밖의 presence 필드는 Int·Date·열거형이라 크기가 고정이다 — 빈틈은 일정뿐이었다.
  가드: `testAdoptScheduleRejectsOversizedPeerStrings`, `testScheduleWithAHugeNameIsNeitherAdoptedNorRelayed`.

- **손으로 쓴 `init(from:)`·`CodingKeys`는 필드 하나 때문에 전체 Codable을 맡기지 않는다.** `schedule` 하나를 너그럽게
  읽으려고 `TeamPresence`의 12개 필드를 모두 손으로 옮겼는데, 이러면 다음 선택 필드를 키 목록이나 디코더에서 빼먹어도
  컴파일되고 그 값은 조용히 오가지 않는다. 필드 하나만 다르게 읽을 때는 프로퍼티 래퍼(`@LossyOptional`)와 컨테이너 오버로드로
  그 필드에만 적용하고 나머지는 합성 Codable에 둔다. 가드: `testEveryOptionalFieldSurvivesARoundTrip`(모든 선택 필드를 채워
  왕복; 키 목록에서 `takenItemSlot`을 빼면 실패하는 것을 확인).

## 외부 로그·사용량 소스

- **토큰 파일 파서는 외부 도구의 실제 직렬화 구조체(중첩 객체)를 반영해야 한다.** `jetski-standalone-oauth-token`
  파일에서 `json["token"]`은 단순 문자열이 아니라 `{"access_token": "...", "refresh_token": "...", "expiry": "..."}`
  형태의 중첩 객체다. 기존 `readTokenFile`이 `json["token"] as? String`만 처리하여 유효한 토큰 파일이 있어도
  항상 파싱에 실패했다. 백그라운드 자동 폴은 키체인 상호작용을 차단(`allowKeychainPrompt: false`)하므로
  파일 파싱이 실패하면 갱신이 중단되었고, 수동 갱신 시에는 키체인 암호 프롬프트가 발생했다(macOS 키체인은
  Antigravity CLI가 새 토큰을 쓸 때 `security add-generic-password -U`로 ACL을 초기화해 "항상 허용"이 지워짐).
  해결: `readTokenFileCredential`에서 `parseCredential`을 재활용하여 중첩 객체(`access_token`),
  문자열 토큰(`token`), 최상위 `access_token`을 모두 수용하고 `refresh_token`을 통한 자동 갱신을 지원한다.
  Google의 네이티브 앱 OAuth 가이드에서는 `client_secret`이 선택 사항으로 기술되어 있으나, Antigravity
  클라이언트는 갱신 시 `client_secret`을 요구하는 클라이언트 고유 제약(`client-specific requirement`)이 있어
  함께 전송한다. 또한 만료 직전(near-expiry) 계정 전환 시 이전 계정 캐시로 잘못 폴백하지 않도록 동일 출처
  검증(`isSameSourceCredential`)을 통해 같은 계정의 갱신 캐시만 디스크의 만료 토큰보다 우선 유지한다.
  가드: `testAntigravityAutoPollReadsNestedTokenObject`·`testAntigravityAutoPollPicksUpNestedTokenSwitch`·`testNearExpiryAccountSwitchDoesNotFallBackToPreviousCachedAccount`·`testExpiredFileRefreshesAndSubsequentPollRetainsRefreshedToken`.

- **토큰 파일 검색 경로는 지원하는 외부 에디션의 실제 저장 위치를 전수 포함해야 한다.** `LocalAntigravityUsageReader`는
  `antigravity`, `antigravity-cli`, `antigravity-ide` 세 경로를 모두 지원하지만, `AntigravityTokenCache.defaultTokenFileURLs`는
  `jetski-standalone-oauth-token`과 `antigravity/` 하위 경로만 탐색하여 공식 CLI(`agy`)가 기본 저장하는
  `~/.gemini/antigravity-cli/antigravity-oauth-token`을 누락했다. 유효한 토큰 파일이 디스크에 있어도 탐색되지 않아
  백그라운드 자동 폴이 `keychainInteractionNotAllowed`로 매 분 실패했고, 한도가 stale 상태가 되어 사용자가
  "Actualiser(갱신)"를 누를 때마다 macOS 키체인 암호 프롬프트가 강제되었다. 또한 `disableKeychainAccess` 토글 시
  토큰 파일 존재 여부와 무관하게 한도 조회를 중단하던 문제가 있었다.
  해결: `defaultTokenFileURLs`에 `antigravity-cli`, `antigravity-ide`, `antigravity-oauth-token`,
  `ANTIGRAVITY_TOKEN_FILE` 환경변수 및 앱 상태 경로를 전수 등록하고, `hasTokenFile`을 제공하여 키체인이
  비활성화된 상태에서도 토큰 파일 기반 무프롬프트 자동 갱신을 보장한다.
  가드: `testDefaultTokenFileURLsIncludeCLIAndIDEPaths`·`testHasTokenFileReflectsDiskPresence`·`testRegisteredNamesCoverEveryProviderOverride`.

- **append-only SQLite watermark 루프를 프로바이더마다 복사하지 마라.** Cursor 와 Copilot 이
  같은 `didReset` / `highWater == 0` 규칙을 두 벌로 들고 있으면 한쪽만 고친 수정이 다른 쪽에 남는다
  (#157). 루프는 `scanIncrementalStores` 한 곳, 포맷만 콜백. 회귀는 공유 헬퍼 테스트 **그리고**
  Copilot-only / Cursor-only 각 경로(A\|\|B 의 B 단독)를 모두 밟아야 한다.
- **리뷰 라운드가 끝나지 않는 건 리뷰어 탓이 아니라 형제 인프라를 우회한 탓이다.** Aside 프로바이더는
  `LocalAdditionalUsageCache` 를 안 타고 리더를 직접 완결해서 독립 리뷰가 3라운드 이어졌다(2026-09-10):
  1라운드 파서·루트 스냅샷, 2라운드 0토큰 턴·실패를 `[]` 로 접기, 3라운드 세션 삭제 감소·영구 실패
  throw. 뒤의 두 라운드 지적은 앞 라운드 *수정*이 만든 것이고(아래 항목), 캐시를 탔으면 부류 자체가
  없었다. 규칙: 새 소스는 캐시 위에서 시작(`provider-extension.md`), 리뷰가 두 번째 라운드에서도
  medium 을 내면 개별 fix 를 멈추고 "형제와 다른 경로가 어디냐"를 먼저 묻는다.
- **실패 처리를 고칠 때는 소비자(`UsageStore.refresh`)의 세 가지 결과 처리를 먼저 읽는다.** throw →
  `failedIDs`/`lastErrorDescription` + `lastUpdated` 정지(앱 전체), nil → 스냅샷 제거("안 썼음"),
  enrichment OK=false → 이전 값 유지. Aside 에서 스킵을 `[]` 로 접어 BUSY 한 번에 탭이 사라지고
  주/월이 0 으로 덮였고(2라운드), "전부 실패면 throw" 로 고치자 `no such table` 같은 영구 조건이
  매 리프레시 throw 해서 다른 프로바이더 숫자는 갱신되는데 "Updated 5 hours ago" 가 굳었다(3라운드).
  최종 결정: 캐시 위의 로컬 소스 리더는 **throw 하지 않는다** — 못 여는/못 읽는 DB 는 스킵하고,
  전부 실패면 `[]` 를 돌려 `dedupKeepMax(existing + loaded)` 가 이전 값을 유지한다(캐시가 무효화될
  때까지 — Settings 저장·월 경계·재시작). 회귀 테스트는 **소스 텍스트가 아니라 캐시를 실제로
  통과**시킨다: `LocalAdditionalUsageCache(asideRootsOverride:clock:)` + `LocalAsideProvider(cache:)` 로
  30초 엔트리를 clock 으로 넘겨 두 번째 스캔이 정말 `existing` 과 병합하는지 본다(`AsideUsageTests`).
  소스 텍스트 검사로 병합을 "고정"했던 첫 버전은 리뷰에서 걸렸고, 행동 테스트로 바꾸자마자
  세션 삭제를 "DB 재생성"으로 오판하는 `MAX(id)` 리셋 감지 버그를 첫 실행에서 잡았다(2026-09-10).
- **이전 코드의 opt-in 플래그를 옮길 때 형제가 왜 안 켰는지 먼저 본다.** Aside 를 캐시로 옮기며
  원본의 `includeModels: true` 를 그대로 가져갔는데, `sessions.model` 은 세션의 *현재* 모델이라
  캐시가 다시 채워질 때마다(무효화·월 경계·재시작) 이전 턴 전부가 새 모델로 재분류된다. 이 옵션은
  per-turn 모델이 기록되는 Pi 만 켠다. 회귀: provider 경유 `fetchDaily()?.models == nil`.
- **파싱 뒤에 걸린 필터는 출력을 줄이지 일을 줄이지 않는다.** `modifiedSince` 가 호출부에선
  스캔 창처럼 보이지만, 행 watermark 가 있는 리더에서만 창이다. 통문서 저장(Kiro 가 대화 JSON 을
  제자리 재기록)은 창을 파싱 *뒤에* 적용해서 읽기·`jsonObject` 비용이 그대로다(실측 30×80턴:
  리턴 0건도 37ms). watermark 를 못 쓰면 싼 게이트는 파일 자신의 signature 다 — 이미 있는
  `LocalAntigravityUsageReader.signature` 를 재사용한다(`.db`/`.sqlite3` + `-wal`, `-shm` 제외).
  첫 스캔은 기록된 signature 가 없어 건너뛰지 않고, 실패한 open 은 슬롯을 차지하지 않는다.
  `.kiro` 캐시는 `existing + loaded` 를 병합하므로 빈 스캔은 캐시를 지우지 않는다.
  signature 는 process-lifetime 맵이 아니라 `Cached` 의 `kiroSignatures` 로 entries 옆에 둔다 —
  month-key 가 바뀌면 `previous` 가 nil 이라 skip 도 같이 죽는다. skip 이 `existing` 없이
  남으면 `[] + []` 로 주/블록 합계가 0 이 된다(#179). (#178)
- **외부 로그 포맷은 *상위 소스의 writer* 로 검증한다 — 내 픽스처는 증거가 아니다.** 새 프로바이더 파서를
  쓸 때 "이렇게 생겼을 것"으로 픽스처를 만들면 파서와 픽스처가 같은 오해를 공유해 테스트가 전부 통과하면서
  실사용은 0 을 표시한다(#133: 봉투 래퍼 키를 `update` 로 봤으나 실제는 `params`, `timestamp` 는 ISO 문자열이
  아니라 Unix `u64` 초 — 실제 라인은 한 건도 안 잡혔다). 순서: ① 업스트림에서 *쓰는* 코드(직렬화 구조체·serde
  계약 테스트)를 열어 키·타입·의미를 확정 ② 그 계약으로 픽스처 작성 ③ 가능하면 실파일 1건 캡처. 특히
   **같은 스펠링이 표면마다 의미가 다를 수 있다**(Grok `inputTokens`=캐시 포함 durable wire vs `input_tokens`=캐시
   제외 헤드리스 투영) — 별칭으로 합치면 캐시분을 두 번 빼거나 두 번 더한다.
- **외부 도구의 새 저장 테이블은 기존 테이블과 공존할 수 있다 — V2 writer 를 확인한다.** OpenCode V2 는
  assistant 사용량을 `session_message` 에 쓰고, 이전 `message` projection 만 읽던 PokeTokenBar 는 업데이트 뒤
  새 세션 사용량을 놓쳤다. 예전 테스트는 `message` 만 만든 fixture 였기 때문에 파서 회귀로 보이지 않았다.
  V2 에선 indexed `time_created` 로 최근 assistant 행을 읽고, nested `model` 과 분리된 `reasoning` 을 매핑하며,
  두 세대 테이블을 합쳐도 message ID 로 dedup 한다. 외부 도구의 저장 형식이 바뀌면 예전 projection 이 남아
  있다는 이유로 새 writer 도 계속 그 테이블을 채운다고 가정하지 않는다. 가드:
  `testOpenCodeReadsV2SessionMessagesAndMergesLegacyUsage` — 두 테이블 동시 존재, 새 V2 assistant 형식,
  비사용자 데이터 행 제외, reasoning 합산, V1 이력 병합을 함께 고정한다.
- **스토리지 컷오버는 옛 파일명만 보면 커스텀 루트도 0이다.** 업스트림이 `data.sqlite3` 에 쓰기를
  멈추고 `~/.kiro/sessions` JSONL 로 옮겼는데, 리더가 루트마다 sqlite 만 열면 Settings 의
  `~/.kiro` 추가 폴더가 no-op 가 되고 최근 사용량이 0 으로 보인다(#236). 규칙: ① 기본 루트 목록에
  *새* 레이아웃 경로를 넣는다 ② 커스텀 루트는 레이아웃으로 분류해 스캔한다(`data.sqlite3` 존재 여부로
  폴더를 버리지 마라) ③ 옛 스토어는 폴백으로 남긴다 ④ 픽스처는 writer 계약(실파일에서 뽑은
  envelope — tokscale/codeburn 의 Kiro 파서 테스트). 같은 파일에 크레딧 필드가 있어도 달러가 아니면
  `reportsCost` 를 켜지 마라. 가드: `testExtraRootFindsJsonlSessionsWithoutSqlite`·
  `testCliJsonlSessionIsReadFromWriterShapedEvents`·`testV3MessagesJsonlSessionIsRead` —
  JSONL 스캔을 끄면 이 셋이 빨개져야 한다(헬퍼 복사본이 아니라 프로덕션 `kiroEntries`).
- **A valid event envelope does not guarantee complete content-block coverage.** Kiro CLI
  2.25.0 JSONL contains `toolUse.data.input`, `toolResult.data.content` (nested `text`/`json`),
  and `thinking.data.text`, but the reader accepted only `kind=text`. Tool-heavy sessions
  therefore lost both current content and the history resent in later turns. Existing CLI
  fixtures contained only text; the separate v3 tool-call test did not exercise this path.
  Dispatch known block kinds, reusing the existing JSON-value byte estimate for arguments
  and JSON results. Do not traverse the entire event: IDs, thinking signatures/redacted data,
  images, and the duplicate `ToolResults.data.results` bookkeeping are not additional text.
  `KiroContentBlockTests` uses synthetic writer-shaped blocks to cover input/output routing,
  tool-only responses, UTF-8/nested JSON, cross-day history, Clear, late-result rescans and
  keep-max deduplication. Kiro's entries/signatures are memory-only, so no disk-cache version
  changes are needed. This fixes missing content, not the estimator's existing limitations:
  bytes/4 and per-prompt history are not authoritative per-request/billed token counts.

- **Antigravity의 생성 시각은 `gen_metadata` 한 곳에 고정돼 있지 않다.** 구 포맷은
  `chat_start_metadata.created_at`에 시각을 넣지만, 현재 포맷은 그 필드를 비우고 `steps.metadata`에
  타임스탬프를 둔다(`8 finished_at`, 없으면 `1 created_at`). 토큰 필드는 유지되므로 `gen_metadata`만
  읽으면 오늘 사용량이 통째로 `nil`이 된다. 연결은 네 단계다: 구 포맷의 직접 시각 → `response_id`
  1:1(`steps.metadata` 의 `9.11`) → 같은 `execution_id`(`12`) 안에서의 등장 순서 → 스토어 mtime.
  **행 순서(`idx`)로 잇지 마라** — `gen_metadata.idx` 는 자기만의 조밀한 수열이라 같은 대화 안에서도
  `steps.idx` 와 분 단위로 어긋난다. mtime 이 최후수단인 이유는 스토어 하나에 값이 하나뿐이라
  대화의 앞선 날들을 마지막 기록일로 끌어오기 때문이다(실측: 신포맷 스토어 10개에서 11,523,909 토큰이
  하루 뒤로 이동하고 원래 날짜는 0이 됐다).
  **`steps` 는 종류를 가리지 않고 전부 읽는다** — 쿼리에 `step_type` 조건이 없다. `execution_id` 를 가진
  행은 generation 이 아니어도 순서 대응 후보 목록에 들어가므로, 3단계는 그 실행의 다른 step 시각을
  집어갈 수 있다(합성 스토어로 확인). 실제 스토어에서 이 혼입이 얼마나 되는지는 **아직 측정되지 않았다** —
  근거는 `created_at` 이 남아 있는 스토어와 대조해 ~2분 이내라는 것뿐이다. 좁히려면 `step_type` 값을
  실데이터로 먼저 확정하라: 테스트 픽스처의 `steps` 에는 그 컬럼 자체가 없어, 실측 없이 조건만 넣으면
  스토어를 통째로 못 읽는 쪽으로 무너진다. 회귀 가드는
  `testCurrentGenerationFormatUsesStepMetadataTimestamp`·`testTheJoinIsTheExecutionIdAndNotTheRowIndex`·
  `testStepTimesAreHandedOutInOrderWithinAnExecution`·`testStoreMtimeRemainsTheLastResort`.
- **usage 필드 이름만 보고 버킷을 합치지 마라 — 상위 writer/type 계약의 포함 관계를 확인한다.** Pi의
  `reasoning` 은 별도 output이 아니라 `output`의 부분집합인데 Gemini 원본의 별도 `thoughts` 처리와 같은
  방식으로 더하면 실사용량이 두 번 집계된다. 반대로 provider가 `thoughts`를 아직 output에 접지 않았다면
  빼면 안 된다. 회귀 픽스처는 `input + output + cacheRead + cacheWrite == totalTokens` 같은 **writer의
  불변식**을 함께 고정하고, 매핑을 고치면 해당 provider cache parser version을 올려 기존 blob도 재파싱한다.
- **breakdown 이 비고 `total` 만 남은 이벤트는 "무조건 total 신뢰"도 "무조건 0"도 틀리다.** Codex
  `last_token_usage` 가 성분 전부 0 이면서 `total_tokens` 만 채운 턴이 있다(#278, ~2.5%). 그 total 이
  세션 전체와 같거나 cumulative 도 total-only 이거나(또는 직전 대비 cumulative.total 이 증가)하면
  실사용이라 Entry 에 넣어야 하고, fork post-replay 의 zero-context 턴
  (`Fixtures/CodexFork/child.jsonl` L11: cumulative 성분은 채워져 있고 last.total 만 고아)은
  cumulative 성장에 안 들어가므로 0 으로 남겨야 한다. 가드:
  `testCodexTotalOnlyLastUsageCountsWhenItMatchesSessionTotal`·
  `…WhenCumulativeIsAbsent`·`…WhenCumulativeGrew`·
  `testCodexUnchangedCumulativeWithDifferentLastVectorIsPreserved`·
  `testCodexManualForkFixtureKeepsOnlyPostReplayUsage`. 매핑 변경 시 `codexParserVersion` 을 올린다.
- **패밀리 단가 폴백은 "같은 패밀리 = 같은 네 단가"가 깨지는 순간 틀린다.** Fable 5.1 은
  input/output/cache-write 는 Fable 5 와 같고 cache-read 만 $1.00 → $0.25 로 바뀌었는데,
  `contains("fable")` 폴백이 Fable 5 단가를 적용해 캐시 위주 세션 비용을 4× 로 부풀렸다(#277).
  패치·마이너가 단가 한 칸만 바꿀 수 있으면 **정확 매칭 행을 표에 추가**하고, 폴백이 우연히 맞는
  모델(예: `claude-opus-5` → opus 폴백)은 건드리지 않는다. 가드: `testPricingExactAndFallbackAndZero`
  의 `claude-fable-5-1` cache-read $0.25 단언.
- **폴백을 제거하는 것은 그 폴백이 덮던 *모든 입력*에 대한 동작 변경이다 — 지우기 전에 그 입력을 열거하라.**
  #289 가 `contains("opus")` 류 패밀리 폴백을 없앨 때(그 자체는 #277 때문에 옳다) 폴백으로만
  가격이 매겨지던 `claude-opus-5`·`claude-sonnet-5` 의 정확 매칭 행을 넣지 않아, 현행 세대 Claude
  사용량 전체가 `estimatedCost == nil` → `CostCoverage.unavailable` → 비용란이 "계산 불가" 로
  비었다(#303, v2.5.4 로 출시됨). 바로 위 항목이 "폴백이 우연히 맞는 모델은 건드리지 말라" 고
  경고해 뒀는데도 폴백만 지워졌다. 규칙: 폴백 삭제 PR 은 **삭제 전 그 폴백에 걸리던 모델 식별자를
  실제 로그에서 grep 해 열거하고**, 각각에 정확 매칭 행을 같은 커밋에 추가한다.
- **"미지 입력 → nil" 을 단언하는 테스트는 신규 현행 모델이 미지로 떨어지는 순간 결함을 *정답으로
  고정한다*.** #289 는 `XCTAssertEqual(ModelPricing.rate(for: "claude-opus-5"), .zero)` 를 남겼고
  (`testPricingExactAndFallbackAndZero`), 그래서 스위트는 #303 을 잡기는커녕 초록으로 보증했다.
  line coverage 도 무력하다 — `.unavailable` 분기는 기존 테스트가 이미 실행하므로 게이트를 통과한다.
  대칭 가드가 필요하다: 미지 이름이 값을 빌리지 않는지(`testUnknownNamesNeverBorrowFamilyPrices`)
  **와** 실제로 로그에서 읽히는 현행 식별자가 전부 가격을 갖는지
  (`testModelsReadFromProviderLogsAreAllPriced`) 를 둘 다 단언한다. 미지로 남겨 두는 단언에는
  **아직 출시되지 않은** 이름만 쓴다(`claude-opus-6`), 현행 세대 이름은 절대 쓰지 않는다.
- **새 provider를 추가할 때 reader/cache만 연결하면 Settings의 custom-root contract가 조용히 빠진다.** `CustomScanRoots`는
  provider별 `curatedRoots(for:)`와 실제 reader의 `CustomScanRoots.storedValue(for:)` 조회를 모두 registry로
  취급한다. Pi 추가 때 reader/cache/provider는 등록했지만 이 두 지점을 빠뜨려 CI의
  `testEveryRegisteredProviderConsultsItsOwnCustomScanRootsKey`가 `pi`만 잡았다. 회귀는 provider id 전체를
  소스 스캔하는 테스트를 유지하고, 새 provider마다 curated default와 runtime union을 함께 추가한다.
- **사용량 소스의 "복사·재기록" 경로를 먼저 찾아라 (이중집계·재날짜화).** 세션 fork·재생·서브에이전트는 같은
  지출을 여러 파일에 남기거나 시각을 다시 찍는다. 규칙: ① dedup 키는 *턴 자체* 의 전역 유일 id(파일·세션 경로를
  섞지 마라 — 복사본이 별건이 된다) ② 시각은 *기록* 시각이 아니라 *턴* 시각(fork 는 봉투 timestamp 를 새로
  찍는다 → 주/월 합계가 포크 시점으로 몰린다) ③ 부모에 접혀 들어오는 자식(서브에이전트) 세션은 제외.
  다중 계정 귀속에서는 dedup 된 턴이 발견된 **모든 세션 id를 보존**하고, 턴 시각 이전의 프롬프트가 있는
  원본 세션을 우선한다. 분기 세션의 미래 프롬프트로 과거 턴을 귀속하지 않는다. 회귀 가드는 같은 턴의
  원본·분기 복사본을 양쪽 입력 순서로 넣어 합계 1회와 동일한 원본 계정 귀속을 함께 단언한다.
- **로그 루트는 한 곳이 아니다.** Claude 사용 로그는 CLI 기본 위치 말고도 `CLAUDE_CONFIG_DIR`(콤마 다중),
  XDG 스타일 `~/.config/claude/projects`, 그리고 Claude Desktop 임베디드 세션(`local-agent-mode-sessions`/
  `claude-code-sessions` 아래 세션마다 자체 `.claude/projects`)에 남는다. 루트 추가는
  `LocalUsageReader.claudeProjectRoots` 한 곳에서만 한다. 임베디드 루트 탐색은 `.claude` 가 **hidden** 이라
  `skipsHiddenFiles` 를 켜면 조용히 0건이 된다 — 회귀 가드
  `testEmbeddedRootsFindHiddenClaudeProjectsDirs` 가 그 브랜치를 밟는다.
- **커스텀 스캔 루트는 기본 루트에 더하기만 한다.** 사용자가 지정한 조상 경로(`~`, 홈 폴더)를
  `normalizedRoots` 에 넣으면 짧은 쪽이 이기고 기본 `~/.claude/projects` 가 접혀 사라진다.
  `jsonlFiles` 는 `skipsHiddenFiles` 를 쓰므로 살아남은 `~` 은 `.claude` 아래로 내려가지 않고
  합계가 조용히 0 이 된다(#162-B). 가드: `testAncestorCustomRootDoesNotEvictCuratedDefault`.
  `skipsHiddenFiles` 자체는 건드리지 않는다. 저장 키는 `customScanRoots.<providerID>` —
  공용 키에 Claude 전용 값을 넣으면 일반화할 때 마이그레이션이 생긴다(#162-C, #177).
  조상 판정은 `extra + "/"` 접두사만으로 부족하다 — 커스텀이 `/` 이면 접두사가 `"//"` 가 되어
  기본 루트를 안 접는 대신 **디스크 전체를 스캔**한다. `/` 는 모든 경로의 조상으로 취급하고 버린다.
  Codex 세션-id 인덱스는 **모든 루트를 모은 뒤에** 한 번만 prune 하고, parent-closure 도
  루트 합집합 위에서 한 번만 확장한다. 루트마다 확장하면 커스텀 폴더의 fork 가
  `~/.codex/sessions` 의 부모를 못 보고 replay 를 이중 집계한다.
  OpenCode/Hermes/Cursor/Copilot/Kiro 의 30초 엔트리 캐시는 저장 시 `invalidateScanCache` 로
  비운다 — Claude 의 300초 루트 캐시만 비우면 추가 폴더가 TTL 동안 안 보인다.
- **GUI 앱은 셸 환경을 상속하지 않는다 — 환경변수로 설정되는 경로는 셸에 물어봐야 한다.** Finder/launchd 로
  뜬 `.app` 의 `ProcessInfo.processInfo.environment` 에는 `~/.zshrc` 의 export 가 없다. 그래서
  `CLAUDE_CONFIG_DIR` 같은 값을 프로세스 환경에서만 읽으면 **CLI·`swift test` 에서는 통과하고 배포된 앱에서만
  0 을 표시**해 재현이 안 된다. 레포에 이미 같은 부류의 해법이 있다(`BinaryLocator.shellResolve` 가 PATH 때문에
  `zsh -ilc` 를 띄운다) — 새 환경변수도 `BinaryLocator.shellEnvironmentValue` 로 조회한다. 단 셸 spawn 은
  실측 ~0.44s 라 **프로세스 생애 1회만**(`static let` lazy) 캐시하고, 주기적으로 갱신되는 캐시(TTL)에 묶지 마라 —
  그 값을 안 쓰는 대다수 사용자까지 갱신마다 비용을 문다.
- **위 규칙이 문서에만 있으면 다음 프로바이더가 그대로 어긴다 — 조회 지점을 하나로 모으고 테스트로 막아라.**
  실제로 그렇게 됐다: 규칙을 적어 둔 뒤 추가된 `OPENCODE_DATA_DIR`·`HERMES_HOME`·`COPILOT_HOME`·`GROK_HOME`
  네 개가 전부 `ProcessInfo.processInfo.environment` 직독으로 들어왔고, 해당 사용자는 배포된 앱에서만 조용히
  적은 숫자를 봤다. 원인은 구현이 아니라 **강제 수단의 부재**다 — 산문 규칙은 새 파일을 리뷰할 때만 작동한다.
  이제 조회는 `UsageEnvironment` 한 곳이고(이름은 `UsageEnvironment.names` 에 추가),
  `testNoProviderReadsUsageLocationEnvDirectly` 가 `Sources/` 를 스캔해 직독 지점을 실패시킨다(허용 목록은
  사용자 override 가 아닌 것만 — `SHELL`·`PTB_STATE_DIR` 등). 조회는 **이름 수와 무관하게 spawn 1회**로 묶는다
  (`shellEnvironmentValues`) — 이름마다 띄우면 프로바이더가 늘수록 기동이 그만큼 느려진다.
  프로세스 환경에 전부 있으면 셸을 아예 안 띄우는 분기도 함께 가드한다(`…SkipsShellLookup`).
  `export FOO=` 처럼 **빈 값은 미설정으로** 취급한다 — 값으로 받으면 없는 경로를 스캔하고 조용히 0 이 된다.
  **`UsageEnvironment.value("X")` 만 있고 `names` 에 `X` 가 없으면 영원히 nil 이다.** Kiro 는
  `environmentPaths("KIRO_CLI_HOME")` 로 읽고 있었는데 이름이 레지스트리에 없어, 셸에 export 해 둔
  값이 GUI 앱은 물론 프로세스 환경에서도 안 보였다. 같은 스윕에서 `CURSOR_DATA_DIR` 도 같은 구멍.
  가드: `testSourceLiteralEnvKeysAreAllRegistered` 가 Sources 의 `environmentPaths("X")` /
  `UsageEnvironment.value("X")` 리터럴을 `names` 와 대조한다(#236).
- **디렉터리 탐색은 깊이만 막으면 폭이 안 막히지만, 이름 기반 가지치기는 더 위험하다.** 깊이 가지치기는
  `> maxDepth` 가 아니라 `>= maxDepth` 에서 걸어야 한 단계 더 내려가지 않는다(전자는 상한+1 까지 방문).
  깊이 상한은 **실제 레이아웃 깊이를 테스트로 고정**하고 여유를 둔다 — 경계에 붙여 두면 상위 소스가 한 단계
  중첩하는 순간 조용히 0건이 된다(`testEmbeddedRootsDepthBoundaryMatchesRealLayoutWithHeadroom`).
  **이름으로 가지치는 목록에는 사용자 작업 트리가 될 수 있는 이름을 절대 넣지 마라** — 이름 하나가 *조상*
  으로 걸리면 그 아래 전부가 사라진다. 실측 회귀: 폭을 줄이려고 `uploads`·`outputs`·`build`·`target` 을
  넣었는데, `uploads`·`outputs` 는 실제 세션 레이아웃에 존재하는 디렉터리고 그 안에서 돌린 Claude 세션은
  정당한 루트다 → 원래 고치려던 "조용한 0건"을 그대로 재생산했다. 목록은 패키지·VCS 내부처럼 사용자 코드가
  아닌 것만(`node_modules`·`.git`·`venv`·`.venv`) 두고, 폭 제어의 주 수단은 깊이 상한으로 둔다.
- **가지치기·필터 테스트는 양방향으로 단언하라.** "제외돼야 할 것이 제외됐나"만 보면 "포함돼야 할 것이 함께
  잘렸나"를 못 잡는다. 위 회귀가 정확히 그렇게 통과했다 — `testEmbeddedRootsDoNotDescendIntoBulkDirectories`
  는 `node_modules` 가 잘리는 것만 확인했고, 같은 목록이 정당한 루트를 자르는 건 아무도 안 봤다. 짝이 되는
  가드가 `testEmbeddedRootsFindRootsUnderWorkDirectoryNames` 다.
- **락을 쥔 채 외부 프로세스를 기다리지 마라.** 캐시 갱신 락 안에서 로그인 셸 spawn(최대 8초 대기)이나
  파일시스템 전체 탐색을 하면, `UsageStore` 가 taskGroup 으로 병렬 fetch 하는 다른 프로바이더까지 그 뒤에
  줄 선다. 결과가 idempotent 하면 **계산은 락 밖에서** 하고 락은 필드 대입에만 쥔다(경합 시 중복 계산이
  블로킹보다 낫다).
- **자식 프로세스 출력은 드레인하되, 드레인에 별도의 짧은 상한을 두지 마라.** 파이프 버퍼(64KB) 데드락을
  막으려 백그라운드 드레인으로 바꾸면서 세마포어에 2초 상한을 걸었더니, **종료를 무한정 기다리던 이전 동작에서
  값을 얻던 경우가 nil 이 됐다**(실측 회귀). 셸이 exit 해도 rc 가 띄운 백그라운드 잡(zsh-async·zinit turbo 등)이
  stdout write end 를 쥐고 있으면 EOF 가 늦게 온다 — 드레인은 **전체 타임아웃의 남은 예산**을 줘야 한다
  (실측: 고정 2초 → nil / 남은 예산 → 4.03초에 값). 그리고 포기할 땐 `handle.close()` 로 리더를 깨워라 —
  안 닫으면 `readDataToEndOfFile` 에 박힌 워커 스레드가 호출마다 하나씩 영구히 쌓인다(재시도가 타이머로
  반복되는 상주 앱에서는 하루 수백 개).
- **두 개의 완화책을 동시에 바꾸면 각각은 옳아도 조합이 회귀가 된다.** 이름 가지치기 목록을 줄이면서(정확성)
  깊이 상한을 함께 올렸더니(여유) 열거량이 수백 배로 뛰었다 — 각 변경은 단독으로는 무해했고, 폭을 잡던 것이
  이름 목록이었는데 그걸 줄이는 순간 깊이가 유일한 제어가 됐기 때문이다. 완화책을 조정할 땐 **어느 쪽이 실제로
  비용을 잡고 있었는지 측정**하고 한 번에 하나씩 바꾼다. 최종값은 측정으로 정한다(실측: 깊이 6=놓침,
  7=전부 찾음·방문 100, 8·9=방문 그대로 → 7 이 "놓치지 않는 최소값이면서 비용이 안 느는 지점").
- **`precondition` 은 릴리스 빌드에서도 앱을 죽인다 — 테스트 전용 시임을 지키는 데 쓰지 마라.** 잘못 써도
  결과가 "테스트가 엉뚱한 대상을 본다"에 그치는 실수를 SIGTRAP 으로 키운다(`-Ounchecked` 아니면 안 사라짐).
  도달 불가한 곳이면 더더욱 값이 없다. 우선순위를 주석으로 적거나, 애초에 잘못 쓸 수 없는 시그니처로 바꿔라.
- **하위 레이어 호출이 비싼 초기화를 트리거하지 않는지 보라.** 안내 문구 하나를 고르려고 부른 함수가
  `static let` 첫 접근 → 로그인 셸 spawn 을 유발해, 자동 폴링 경로의 actor 를 수백 ms~수 초 막을 수 있다.
  값이 필요한 쪽(그 값을 실제로 쓰는 경로)에서 초기화를 트리거하고, 부수적 분기에서는 싼 소스
  (`ProcessInfo.environment`)만 본다.
- **유닛 테스트가 로그인 셸을 띄우면 hermetic 하지 않다.** 프로덕션 진입점(`claudeProjectRoots`)을 테스트에서
  직접 부르면 개발자의 `.zshrc` 가 실행되고, 그 기기에 `CLAUDE_CONFIG_DIR` 이 export 돼 있으면 결과가 달라진다.
  주입 시임(`computeClaudeProjectRoots(configDirValue:home:)`)으로 판정하고, 실환경 확인은 일회성 프로브로
  분리한다.
- **경로 dedup 은 심볼릭 링크를 풀고 대소문자를 무시해야 한다.** `standardizedFileURL` 은 `..`·`.` 만 정리하고
  링크는 그대로 둔다. `~/.config/claude` → `~/.claude` 링크 같은 구성에서 같은 트리를 두 번 열거·파싱하게 된다
  (합계는 전역 dedup 이 지키지만 스캔 비용과 캐시 blob 은 두 배). `resolvingSymlinksInPath()` 로 풀고
  비교 키는 소문자로 — macOS 기본 APFS 는 대소문자를 구분하지 않는다.
- **테스트 시임이 프로덕션 브랜치를 단락시키지 않는지 확인하라.** 다중 루트 순회를 넣고 시임은 단일 루트만
  받게 두면(`claudeRoot.map { [$0] }`) 기존 테스트 전부가 루프를 1회로 단락시켜, 실제로 도는 코드는 무테스트로
  남는다. 새 브랜치를 만들면 **그 브랜치를 밟는 시임**을 같이 만든다(`LocalUsageCache(claudeRoots:)` +
  `testMultipleRootsAreScannedAndDedupedAcrossRoots`, 단일 루트 대조군 포함).
- **파일 밖 상태에 의존하는 판정을 파싱 캐시 안에서 하지 마라.** `LocalUsageCache` blob 은 그 파일의
  `(path, mtime, size)` 로만 무효화된다. 옆 파일(예: Grok `summary.json` 의 `session_kind`)로 결정되는
  포함·제외를 파서 안에서 하면, 근거가 나중에 바뀌어도 파일이 안 바뀌어 판정이 영구히 굳는다. 그런 판정은
  파일 선택 단계(`collect(include:)`)에 둬 매 새로고침 재평가되게 한다.
- **캐시를 붙이는 순간 "다음 새로고침이 다시 읽는다"가 공짜가 아니다.** 부분 읽기(SQLITE_BUSY·손상 페이지)를
  버리는 가드는 **재시도가 실제로 오는 경우에만** 가드다. TTL 시절엔 만료가 재시도를 보장했지만
  `(path, mtime, size)` 키로 바꾸는 순간 그 보장이 사라진다 — 실패 결과를 *현재* signature 아래 blob 으로
  넣으면 파일이 가만히 있는 한 그 소스는 영구히 "사용량 없음"으로 읽힌다. 규칙: ① 읽기 결과를 `[]`·`nil` 로
  접지 말고 **실패와 빈 값을 구분하는 값**으로 돌려라(`LocalAntigravityUsageReader.ConversationRead`)
  ② 일시적 실패는 캐시에 **쓰지 말고** 이전 blob 을 *옛 signature 그대로* 이어받아 다음 스캔이 다시 읽게
  하라 ③ 영구적 사실(기대 테이블이 아예 없는 파일)만 빈 값으로 캐시한다 — 안 그러면 대화가 아닌 DB 를 매
  새로고침 재오픈한다. 같은 이유로 **창(window) 필터를 캐시 단위 안에 굽지 마라**: blob 은 그 창보다 오래
  살아서 다음 날 조용히 행이 빈다. 캐시는 무필터로 담고 조립 시점에 좁힌다(`assemble(_:since:)`).
  회귀 가드: `testIncompleteScanKeepsThePreviousRowsUnderTheirOldSignature`·
  `testUnreadableStoreIsNotCachedAsAnEmptyConversation`·`testDatabaseWithoutTheExpectedTableIsCachedAsEmpty`.
- **캐시 무효화 키에 *내 읽기가 건드리는 파일*을 넣지 마라.** WAL 의 `-shm` 은 읽기 전용 커넥션도 read mark 를
  쓴다. 키에 넣으면 스캔이 방금 쓴 blob 을 그 스캔 자신이 무효화해 **히트율이 영구히 0** 이 된다 — 교체하려던
  TTL 보다 나쁘다. 커밋은 `.db`(체크포인트)나 `-wal`(append) 에 반드시 남으므로 키는 그 둘의 최신 mtime +
  크기 합이면 충분하고, 같은 이유로 창 판정에도 `-shm` 은 무의미하다(그것만 새롭다 = 누가 *읽었다*).
  그리고 **stat 은 읽기 앞에서** 한다 — 뒤에서 하면 읽는 중에 들어온 커밋이 이미 최신처럼 보이는 signature 에
  굳어 영영 안 읽힌다. 회귀 가드: `testShmChurnDoesNotInvalidateTheBlob`·`testWalCommitInvalidatesTheBlob`.
- **실패가 흔적을 안 남기면 "안 썼음"과 구분되지 않는다.** 외부 소스 리더가 실패를 `[]`/`nil` 로 접으면 사용량
  0 과 같은 값이 된다. 프로바이더별 탭이 붙은 뒤엔 숫자가 조금 낮은 정도가 아니라 **탭이 통째로 사라진다**
  (`UsageStore` 는 `today != nil` 이거나 활성 블록이 있을 때만 스냅샷을 만든다). 로그를 남기되 세 가지를 지켜라:
  ① **판정은 순수 함수로 분리** — `AppLog.write` 는 `AppEnv.isBundledApp` 가드로 xctest 에서 조기 return 하므로
  로그 파일을 보는 테스트는 아무것도 커버하지 못한다(§알림의 같은 규칙). ② **양을 묶어라** — 읽을 수 없는
  소스는 매 새로고침 다시 읽히므로(기본 2분 = 720회/일) 대상마다 한 줄이면 2MB 로그가 하루에도 여러 번
  회전해 크래시 이력을 밀어낸다. 스캔당 상위 N개만 이름을 남기고 나머지는 개수로 접는다. ③ **영구적 사실은
  로그하지 마라** — "이 파일엔 그 테이블이 없다"는 바뀌지 않으므로 영원히 반복된다.
  회귀 가드: `testIncompleteScanDropsTheConversationAndNamesTheReason`·`testLossLogNamesAFewStoresAndCountsTheRest`·
  `testDatabaseWithoutTheExpectedTableIsNotReportedAsALoss`.
- **크기 상한이 없는 사용자 파일을 통째로 읽지 마라.** `String(contentsOf:)` 가 파일 크기만큼, 뒤따르는
  `split` 이 다시 그만큼 저장소를 만든다. 라인 단위 `autoreleasepool`(#94)은 `JSONSerialization` 객체는
  배출해도 **원본 문자열과 split 저장소는 못 놓는다** — 실사용에서 21 GiB Codex rollout 하나가 앱 풋프린트를
  20 GiB 까지 밀어올렸다. 전환은 `FileHandle` 청크 스트림(`forEachCodexLine`)이고 두 가지가 핵심이다:
  ① **개행 분할은 바이트 `0x0A` 로** — UTF-8 연속 바이트는 모두 ≥`0x80` 이라 개행이 멀티바이트 시퀀스
  안에 들어갈 수 없어 청크 경계에서 문자가 깨지지 않는다. ② **청크마다 `autoreleasepool` 경계를 둔다** —
  `FileHandle` 이 bridge 한 `Data` backing 이 바깥 풀까지 살아남아, 청크가 작아도 파일 전체를 읽을 때까지
  RSS 가 누적된다. #94 에서 "스트리밍이 오히려 메모리를 악화시켰다"고 판정한 원인이 이 경계 부재였다 —
  **그 판정을 근거로 스트리밍 자체를 배제하지 마라.** 실측(실기기 rollout 59개·201MB·최대 103MB, release):
  peak RSS 416→66 MiB, 파싱 14.25→2.16s, 엔트리 출력은 바이트 동일. **prefilter 는 표현에 달렸다** —
  `String.contains` 는 grapheme 스캔이라 넣으면 느려지고, 같은 판정을 `Data.range` 바이트 탐색으로 하면
  이득이다("파싱 줄 수를 줄이면 빨라진다"가 표현에 따라 참·거짓이 갈리는 자리). 아직 통째로 읽는 곳:
  `parseClaudeFile`·`parseGrokFile`(`String(contentsOf:)`), `parseGeminiFile`(`Data(contentsOf:)`).
  **의도적 보류다** — 근거 없는 일괄 전환은 #94 를 반복하므로 프로바이더별 실측 뒤에 바꾼다. 도달 가능한
  부류이긴 하다(실기기 Claude jsonl 863개, 최대 90MB). 회귀 가드: `CodexLargeRolloutPerformanceTests` —
  **opt-in(`POKETOKENBAR_RUN_LARGE_PERF=1` / `scripts/perf-codex-large-rollout.sh`)이라 CI 는 돌리지 않는다.**
  자동으로 막히지 않으므로 이 부류를 건드리면 직접 돌린다. (#184)

- **2단계 갱신에서 파생 상태는 그 값을 *채우는* 단계 뒤에 기록한다.** 사용량 요약의 일별 원장을
  `snapshots = newSnapshots`(phase 1) 직후에 저장했더니, `monthDaily` 는 `fetchEnrichment`(phase 2)
  에서만 채워져 **설치 후 첫 갱신이 통째로 빈 요약**을 만들었다. 두 번째 갱신부터는 phase 1 이 이전
  스냅샷의 `prevMonthDaily` 를 이어받아 우연히 채워지므로, 단위 테스트도 손으로 앱을 열어보는 확인도
  통과한다 — 틀리는 건 첫 갱신 한 번뿐이라 눈에 띄지 않는다(개발 앱 defaults 에 키가 안 생긴 걸 보고
  발견). refresh 파이프라인에 새 파생 상태를 붙일 땐 그 입력이 phase 1/2 중 어디서 채워지는지 먼저
  확인하고, 회귀 가드는 **첫 refresh 한 번**으로 검증한다(`testTheFirstRefreshAlreadyFillsTheLedger`).
- **"없음"을 0 으로 접는 파서는 옵셔널 폴백을 죽인다 — Cursor 페이지네이션.** `hasNextPage(totalCount: Int?)`
  는 총계가 없으면 "꽉 찬 페이지면 계속" 으로 폴백하도록 짜였지만, 호출부가 `intValue(object["totalUsageEventsCount"])`
  를 넘겨 키가 없을 때 `nil` 이 아니라 `0` 이 들어갔다 → `page * 100 < 0` 이 거짓이라 1페이지(100건)에서
  멈추고 나머지 이벤트를 조용히 버렸다. 응답 키 자체를 세 가지(`usageEventsDisplay`/`usageEvents`/`events`)로
  받는 코드라 메타데이터 부재는 설계상 가정된 입력이다.
  **왜 못 걸렀나:** 폴백 테스트(`testHasNextPageWithoutMetadataKeepsPaginatingWhileFull`)가 `hasNextPage` 를
  직접 `totalCount` 생략으로 불러 통과했다 — 실제 루프는 그 인자를 항상 채워 넘기므로 *다른 경로*로 통과한
  false confidence.
  **수정:** `optionalIntValue` — 키 부재·NSNull·파싱 불가면 `nil`.
  **회귀 가드:** `testFetchFilteredEventsWithoutAnyPaginationMetadataKeepsPaginatingWhileFull` 가
  `fetchFilteredEventsForTesting` 으로 루프 전체를 돈다(총계 없음/있음 둘 다). 수정 전 `[1]`·100건으로 실패 확인.
  **스윕:** 이 파일의 다른 `intValue` 호출은 토큰 수라 0 이 올바른 기본값이다.

- **한도 창 구성은 플랜마다 다르다. 특정 창이 항상 온다고 가정하지 않는다.** Ultra 플랜은 5시간 세션 한도를
  없앴고, `oauth/usage` 는 `five_hour: null` 과 주간 창(`seven_day`, `limits[].weekly_all`)만 보낸다
  (2026-10-31 관측). 메뉴바는 Claude 대표 %를 `status.fiveHour` 로 고정해, 주간 66%가 있는데도 Claude 항목이
  통째로 사라졌다. Codex 는 창 길이와 무관하게 `primary` 를 써서 주간 창 하나뿐인 Pro 계정도 정상 표시됐다.
  **왜 못 걸렀나:** 메뉴바 테스트 픽스처가 전부 5h 창을 넣었고, #327 의 다중 계정 테스트는 "주간만 있으면 메뉴바에
  Claude 없음"을 오히려 기대값으로 고정했다. → 좁은 표면의 대표 창 선택은 `LimitStatus.headlineWindow`
  (5h 우선, 없으면 주간) 한 곳에서 하고 메뉴바는 그것만 읽는다. 팝오버 행·알림·캔디·경고는 이미 창별로
  nil 을 견딘다(스윕 완료). 회귀 가드: `UsageStoreTests.testMenuShowsTheWeeklyLimitWhenThePlanHasNoSessionLimit`·
  `testMenuPrefersTheSessionLimitOverTheWeeklyOne`·`testHeadlineWindowPicksTheSessionThenTheWeeklyWindow`,
  `AdditionalClaudeAccountsTests.testTheMenuToolTipOnlyNamesAnAccountBehindAShownPercentage`.

- **통째로 다시 쓰는 캐시의 저장 간격은 캐시가 커졌을 때의 쓰기량으로 정한다.** `LocalUsageCache`는 스냅샷 하나를
  통째로 다시 쓰고 60초 throttle만 있었는데, 매일 쓰는 사용자는 한 달 치(세션 파일 6,838개·항목 28만)가 JSON 72MB,
  압축해도 16MB가 됐다. 쓰는 중인 세션 파일 하나가 새로고침(2분)마다 바뀌어 매번 16MB를 다시 써, 앱 하나가 시간당 약
  500MB·하루 10GB 넘게 디스크에 썼다(macOS `disk writes` 리포트, 실측 137KB/s). **왜 못 걸렀나:** 60초는 캐시가 수 MB일 때
  정한 값이고, 테스트는 throttle의 존재만 봤지 하루 쓰기 횟수나 크기는 재지 않았다. 처음 단 회귀 테스트도 상한을
  `saveInterval`에서 계산해 간격을 되돌려도 통과했다(주입으로 발견, 고정 예산으로 고침). 수정: 저장 간격 30분
  (`saveInterval`). 늦게 저장해도 잃는 것은 그사이 바뀐 파일의 증분 파싱뿐이라 다음 실행에서 저장된 offset부터 다시 읽는다.
  부류 스윕: 주기적으로 다시 쓰는 다른 파일은 세이브(167KB, 새로고침마다)·팀 소식(106KB, 바뀔 때)으로 작다.
  가드: `testADayOfRefreshesRewritesTheSnapshotRarely`(2분마다 바뀌는 파일로 하루를 돌려 다시 쓰기 ≤ 49번).
  남은 일: 파일별로 나눠 바뀐 조각만 쓰면 더 줄일 수 있다.

## 팀 네트워크 (피어 입력)

- **받은 값은 모든 필드를 변조된 앱이 골랐다고 보고, 받는 쪽에서 막는다.** 보안 감사에서 팀 코드 없이 앱을
  마비시키고, 코드가 있으면 시작을 느리게 하거나 팀원을 쫓아낼 수 있음을 재현했다. 팀 테스트가 전부 정직한 앱의
  프레임만 보내서 못 걸렀고, 앞선 사고(일정 문자열, 들어오는 연결, 확성기)를 고칠 때 그 필드만 막고 같은 부류를
  훑지 않았다. 송신 쪽 연타 제한은 변조된 앱에는 없는 것과 같다. 새 메시지나 필드는 `TeamHostilePeerTests` 처럼
  정직한 앱이 보내지 않는 프레임으로 시험한다.

- **상한은 방향마다 따로 세고, 넘친 것은 무작위로 고른다.** 들어오는 연결만 32개로 막고 나가는 연결은 비워 둬서,
  같은 와이파이의 누구나 코드 없이 가짜 서비스 1,000개를 알려 파일 핸들 256개를 다 쓰게 할 수 있었다. 저장이
  실패하고 진짜 팀원도 연결되지 못했다. 이름순으로 고르면 앞쪽 이름을 쓰는 가짜가 진짜를 영원히 밀어내므로
  `TeamDialPlanner.dialPicks` 는 섞는다.

- **저장하는 값을 재야 한다.** `validNickname` 은 공백을 잘라 재고 행은 원본을 저장해서, 뒤에 공백 1MB를 붙인
  닉네임이 통과했다. 검사를 지난 값이 아니라 그대로 저장되는 값을 재고(`validNickname(s) == s`), 파서가 너그러운
  필드도 잰다. `day` 는 앞자리 0을 얼마든지 받았다. 행 하나가 너무 크면 100건 묶음 전체가 프레임 상한에 걸려 정직한
  소식까지 동기화되지 않았다. `assertEveryStringIsBounded` 가 모든 String 필드를 돌므로 새 필드는 저절로 시험된다.

- **자기 신고한 ID로 상태를 만들지 않는다.** 거부 기록을 hello의 멤버 ID로 남겨서, 잘못된 버전의 hello 한 번으로
  진짜 멤버를 5분 잠갔다. 코드를 아는 사람은 누구나 어떤 ID든 말할 수 있다. 다른 버전은 hello마다 거부되므로 기록을
  없애는 것으로 풀렸다. 실시간 프레임은 보낸 사람의 것뿐이라 작성자를 대조할 수 있지만, 동기화 행은 원래 남의 소식이라
  대조할 수 없다. 남은 사칭과 위조는 멤버별 키가 있어야 막는다(사용성 때문에 2026-11-06 보류).

- **화면과 동작으로 지우는 노드는 멈춘 장면에서 만들지 않는다.** 창이 가려지면 `isPaused` 라 지우는 쪽이 돌지 않는다.
  불꽃과 셔터에만 검사가 있고 점프 먼지, 몸통박치기 충격, 반짝임에는 없어서, 점프 프레임 2만 개에 노드가 4만 개,
  메모리가 170MB 늘었다. 받은 프레임으로 노드를 만들면 상한이나 이 검사가 있어야 한다.

- **측정 조건을 실제 앱에 맞춘다.** `swift test` 프로세스는 `ulimit -n 256` 을 줘도 파일 핸들 한도가 6656이라 범람이
  재현되지 않았다. 앱의 한도는 256이고(`launchctl limit maxfiles`) AppKit과 Network는 올리지 않으므로, 시험 안에서
  `setrlimit` 으로 낮춘다. 디버그 빌드의 메인 스레드 시간은 릴리스의 약 세 배였으니 시간은 릴리스로 잰다. 다른 빌드가
  도는 동안에는 5초 제한이 있는 전송 시험이 실패할 수 있다.

- **받은 값이 가리키는 멤버는 "알고 있다"가 아니라 "지금 광장에 있다"까지 본다.** 메타몽의 `decoyOf` 를 `members[id]` 가 있으면
  그대로 따라 그려서, 광장을 떠난 팀원의 복사본도 보였다(명세 §5.6 은 지금 광장에 있는 멤버를 요구한다). 호스트 쪽 두뇌는 광장
  멤버만 고르므로 정직한 앱은 보내지 않는 값이라 테스트가 못 밟았다. 수정: `m.inPlaza` 를 요구하고 아니면 모르는 멤버처럼 이전
  모습을 둔다. 가드: `testACopyOfAMemberNotInThePlazaIsNotShown`(되돌리면 실패), 지도 밖 칸과 연타는 `testAStateOffTheMapIsIgnored`·
  `testABurstOfDittoStatesLeavesTheLastGoodOneShown`.

- **이어 맡기는 쪽이 보이는 상태를 먼저 받아야 한다 — 진짜 호스트의 마지막 소식은 내 첫 틱보다 먼저 사라질 수 있다.** 더 작은 ID 의
  Mac 이 광장을 열면 첫 틱에 호스트가 되는데 `shownDitto` 가 비어 있어 두뇌가 무작위 칸에서 새로 시작했고, 옛 호스트는 내 준비
  소식을 보자마자 물러나 소식을 거두므로 복사본이 모두의 화면에서 사라졌다. 열 때 알리는 쪽의 메타몽을 한 번 받아 그리고 두뇌가
  거기서 이어 간다. 가드: `testASmallerIDOpeningThePlazaCarriesOnTheCopy`(옛 호스트가 이미 물러난 뒤의 첫 틱까지 같은 `decoyOf`·`since`·칸을
  본다; 한 줄을 지우면 실패). 메뉴를 연 사이 복사본이 돌아오면 고른 일을 버린다(`testAMenuOnACopyThatTurnedBackDoesNothing`).

- **낡은 메뉴 검사는 메뉴가 보여 준 것으로 한다 — 다른 Mac이 다시 찍는 시각으로 하지 않는다. 그 자리에서 모습만 바뀌는 대상은
  안내를 직접 다시 그린다.** 메타몽 모습도 몸통박치기 대상이 되면서(머지 전 리뷰에서 발견) 두 가지가 샜다. (1) 메뉴를 연 순간의
  `since` 와 고를 때의 `since` 를 비교했는데, 찾은 Mac은 제 시계로 메타몽 모습을 찍고 호스트 소식이 호스트 시각으로 다시 찍어서,
  모습은 그대로인데 메뉴가 말없이 닫혔다. 반대로 "복사본인가"만 보면 X의 복사본 메뉴로 Y의 복사본에 인사하거나 카드를 연다.
  수정: 메뉴를 연 때와 고를 때의 `decoyOf`(누구 모습인지)가 같아야 한다. (2) 메타몽이 두 모습 모두 대상이라, 바라보는 칸에서
  모습만 바뀌면 대상 바뀜 알림이 오지 않아 안내가 옛 이름에 머물렀다. 수정: `showDitto` 가 모습이 바뀔 때 안내를 다시 그린다.
  **왜 못 걸렀나:** 메뉴 테스트는 모습이 한 번만 바뀌는 경우뿐이었고 시각만 바뀌는 경우가 없었다. 안내 테스트는 처음 그린
  상태만 봤다. 가드: `testAMenuOnTheDittoFormSurvivesTheHostRestampingIt`·`testAMenuOnACopyThatNowCopiesSomeoneElseDoesNothing`·
  `testTheHintFollowsAFormChangeOnTheSameTile`(각각 `since` 비교, "복사본인가" 비교, 다시 그리기 삭제를 주입하면 실패).
  스윕: 다른 `since` 비교는 `foundDittoSince` 하나로, 호스트가 찍은 복사본의 시각끼리 비교하므로 해당 없다.

- **모두가 따르는 결정을 내 장면의 그리기 결과로 정하지 않는다 — 가려진 창은 장면을 멈춰 그리기가 거절된다.** 메타몽 따라 춤추기
  (머지 전 리뷰에서 발견)에서 호스트가 "메타몽을 세워 둘지"를 `playDance` 가 true일 때만 정했다. 호스트의 광장 창이 가려지면
  `setRendering(visible: false)` 로 장면이 멈춰 `playDance` 가 늘 false라, 다른 Mac에서는 메타몽이 춤추는데 호스트의 두뇌는 그대로
  걸어가 버렸다. 춤추는 팀원이 내 화면에서 아직 걸음을 마치는 중일 때도(춤이 걸음 끝을 기다린다) 같은 이유로 첫 판을 놓쳤다.
  수정: 따라 출지는 자리(메타몽 칸과 춤추는 사람의 칸)로만 정하고, 그리기는 그 결과를 따른다. **왜 못 걸렀나:** 호스트 테스트가
  모두 보이는 창이었고, 춤추는 팀원은 늘 서 있었다. 가드: `testAHiddenHostStillKeepsADancingDittoStill`·
  `testADancerFinishingAStepIsFollowedAtOnce`(그리기 결과로 되돌리면 실패). 스윕: 컨트롤러에서 그리기 결과로 정하는 곳은 불꽃
  키(`playFirework`)뿐인데, 내 키 입력의 연타 제한이고 가려진 창에는 키가 오지 않아 해당 없다.

- **새 기능이 같은 영역의 기존 규칙(알은 복사 불가, 되감긴 시계, 같은 알림 한 번만)을 옮겨 받지 않았다 — 메타몽 따라 하기(릴리스 직전 리뷰·감사).**
  게스트 메타몽의 `canBeCopied(... !isEgg)` 규칙이 팀원 메타몽의 몸통박치기·`realLook`·`mimicTargets` 에 없어 알로 변장할 수 있었고,
  변장한 팀원 따라가기가 안 멈추고, `.mimicFound` 를 아무 발신자가 몇 번이든 보낼 수 있었고, 시계가 뒤로 가면 `now - since` 가 음수라
  변장이 5분+α 갔다. **왜 못 걸렀나:** 테스트가 정상 대상(피카츄)만 썼고, 같은 영역의 기존 규칙·한 번만 규칙을 새 경로에 대조하지 않았다.
  가드: `testADittoCannotCopyAnEggTeammate`·`testAHostileFoundBannerIsIgnored`·`testAClockThatJumpedBackEndsMyDisguise*`
  (각 가드를 빼면 실패). 스윕: 시간 차 비교는 `receiverGrace` 한쪽만 막던 것을 `isOver` 로 모았고, 테스트 전용 기록(`appliedMemberLoads`)은
  64개로 제한했다.

- **팀 연결 감사(2026-11-24): 한도는 연결 하나·메시지 한 종류에만 있었고, "얼마나 자주"·"몇 바이트 쌓였나"·"어느 주소가"는 없었다.**
  증상(코드 읽기로 확인, 실행은 안 함): ① 팀원이 `live:false` 소식 프레임을 초당 수백 개 보내면 프레임마다 `team-feed.json`(최대 약 2 MB)을 통째로 다시 쓰고 정렬을 두 번 했다(정렬 비교마다 `Calendar` 를 새로 만들었다). ② Mac 은 읽지 않는 팀원에게 보낸 바이트를 세지 않아 메모리가 계속 늘었다(Windows 는 8 MB 에서 끊었다). ③ 일정·팀 이름·모닥불·얼음깨기는 더 새 도장이면 무조건 받아 저장하고 매번 모두에게 presence 를 다시 보냈다: 한 팀원이 팀 전체를 서로 flood 로 끊게 만들 수 있었다. ④ 모르는 종류 프레임은 비용 0, 끊긴 주소는 곧바로 새 4 MB 를 받고, hello 를 안 하는 링크가 128 칸을 차지했다. ⑤ 확성기는 자기 신고 member ID 별로만 제한돼 ID 를 바꾸면 무제한이었다. ⑥ 팀원이 보낸 `speciesID` 가 어떤 정수든 GitHub 스프라이트 요청이 됐다. ⑦ 인증 안 된 한 주소가 미완료 연결 32개를 채워 팀원을 막을 수 있었다(주소당 상한으로 줄였을 뿐 막지는 못한다: 주소가 계속 바뀌는 IPv6 임시 주소는 우회한다). ⑧ 지워지지 않는 DNS-SD 이름이 표에 끝없이 쌓였다. ⑨ 받은 프로필의 도감은 길이 제한이 없었다.
  **왜 못 걸렀나:** 앞선 팀 입력 항목들이 "값이 범위 안인가"(문자열 길이, 날짜 창, 개수)를 막았는데, 그 방어는 한 프레임의 크기만 봤다. 같은 합법 프레임을 많이 보내는 입력(되풀이 비용)과 상대가 읽지 않는 출력(쌓이는 양)은 어느 테스트도 만들지 않았다. `TeamFeedStoreTests` 는 "프레임당 저장 한 번"을 오히려 못 박았다. Windows 에만 있던 8 MB 한도는 Mac 에 같은 값이 있는지 대조한 적이 없다(`TeamTransportContract` 는 양쪽 같은 시나리오만 돌려 한쪽에만 있는 한도를 못 본다).
  **고침(값은 정직한 클라이언트가 보내는 최대에서 뽑았다, 이름 있는 상수):** `TeamFeedStore.saveDelay`(팀원 프레임은 2초 뒤 한 번에, 내 소식은 즉시, 종료 때 `flush`)·정렬 키는 한 번만 계산·`TeamSession.syncedFrameBurst` 120 + `syncedFramesPerSecond` 2·`TeamTransportRules.maxQueuedBytes` 8 MB(Mac 도 `contentProcessed` 로 센다)·`TeamSession.sharedValueBurst` 20 + `sharedValueInterval` 4초와 `adoptionBroadcastInterval` 2초로 합친 presence·`FrameDecoder.lastFrameCount`(건너뛴 프레임도 `frameCost`)와 복사 없는 오프셋·`helloDeadline` 30초(`silenceLimit` 과 같다: 주 스레드가 멈춘 정직한 앱은 일반 침묵 경로가 먼저 닿고, 끊을 때 `refuse` 가 아니라 `disconnect` 라 우리 쪽 재다이얼이 300초 쉬지 않는다)·`maxUnfinishedInboundPerAddress` 8·`maxLinksPerAddress` 32·`TeamFloodMemory`(끊긴 주소는 10분 동안 기억하고, 그 사이 새 링크는 쌓인 만큼만 토큰으로 시작한다: 부족분은 16초면 메워진다)·`TeamNotifier.megaphoneBurst` 10 + 2초당 1개와 표 정리·`TeamMonSummary.bounded` 의 종 범위·`SpriteStore` 가 404 를 앞면도 기억·`PlazaWindowController.memberLoadTasks`(새 로드가 이전 것을 취소)·`maxDiscoveredNames` 1024(계획표와 Windows DNS-SD 표. 연결된 적 없는 이름부터, 그 안에서 마지막으로 알려진 지 오래된 순으로 버린다)·`TeamMemberProfile.bounded`.
  **부류 스윕:** 받은 값을 저장·다시 보내는 곳(일정, 팀 이름, 모닥불, 얼음깨기)은 presence 와, 점프 이모트가 싣는 얼음깨기(`TeamRuntime` → `showJump` → `learnIceBreak` → `updateIceBreak` → 모두에게 presence) 두 길이다. 처음 고칠 때 이모트 길을 "멤버 상태를 읽을 뿐"이라고 잘못 적어 놓쳤고(리뷰가 잡았다), 이제 `.emote` 도 같은 링크별 예산(`sharedValueChanges`)을 쓴다: 예산 밖의 점프는 그대로 재생되고 얼음깨기만 뺀다. 피어 프레임이 공유 상태 쓰기 + 브로드캐스트를 일으키는 나머지 길을 다시 훑었다: 아이템 칸(`updateTakenItemSlot`)은 내 시계 주변 창 안의 칸으로 한정돼 값이 몇 개뿐이고, 메타몽·변장(`updateDitto`/`updateMimic`)은 내 로컬 동작에서만 불리고 피어 프레임으로는 닿지 않으며(저장도 안 한다), 활동 수(`updateActivity`)는 내 행동만 올린다. 키 도출(7번)은 소유자가 두기로 했다.
  **영구 캡처:** `TeamTransportAuditTests.swift`(한도마다 "넘치게 보내는 피어"와 "정직하게 가장 많이 보내는 피어"를 짝으로), `TeamTransportTests.testALinkWithTooManyBytesWaitingIsDropped`/`testThreeFullFeedSyncsInOneGoAreNotDropped`, `TeamNotificationsTests` 의 확성기 두 건, 계약 테스트 `unfinishedInboundLinksAreCapped`(주소 한 곳 기준으로 바꿈). 가드를 하나씩 되돌려 해당 테스트가 실패하는 것을 확인했다.
  **규칙:** 피어에게서 오는 것은 크기·범위뿐 아니라 **횟수**(프레임당 비용 × 속도), **주소당 몫**, 그리고 **내가 보낸 뒤 쌓이는 양**을 따로 따진다. 새 한도는 정직한 클라이언트의 최대(예: 전체 소식 동기 99프레임, 한 주소 뒤 팀원 열여섯 명)를 이름 붙은 상수의 주석에 적고, 그 최대를 보내는 테스트를 함께 둔다. 한 플랫폼에만 있는 한도는 다른 쪽에도 있는지 대조한다.

## 빌드·도구체인

- **`Sendable` 여부는 SDK마다 다르다 — 파일 범위 전역에는 값 타입만 둔다.** 메타몽 PR(#88)이 테스트 파일 맨 위에
  `private let dittoPicture: NSImage = { … }()` 를 두었다. macOS 26 SDK에서는 `NSImage` 가 `Sendable` 이라 로컬 전체 스위트와
  릴리스 게이트(2956개)를 모두 통과했지만, CI(macOS 15 / Xcode 16.4 / Swift 6.1.2)의 15.5 SDK에서는 "not concurrency-safe"
  컴파일 오류로 main CI가 빨개졌다. **왜 못 걸렀나:** 6.1 툴체인을 쓰는 곳은 CI뿐인데, 빠른 배포 흐름이라 CI를 기다리지 않고
  머지했다(받아들인 비용, 고쳐 나간다). 테스트 코드라 출시된 앱에는 영향이 없었다. **규칙:** 파일 범위 `let` 에는 정수·문자열·
  날짜 같은 값만 두고, `NSImage`·`NSColor`·`SKTexture` 같은 AppKit/SpriteKit 객체는 그 값을 쓰는 타입의 인스턴스 프로퍼티로
  둔다(같은 파일의 `BacklessFetcher.image` 처럼). 스윕: `Tests/`·`Sources/` 의 파일 범위 `let`/`var` 는 모두 값 타입이었다.

- **고정 날짜로 만든 데이터는 실제 시계를 쓰는 저장소에 넣지 않는다.** `PlazaBoardTests`의 한 테스트가 날짜를
  2026-10-30으로 박은 소식을 실제 시계로 도는 `TeamFeedStore`(7일만 보관)에 넣었다. 11월 7일부터 소식이 들어가자마자
  버려져 표시등이 꺼진 채로 CI가 깨졌다. 코드는 바뀌지 않았고 무관한 #80에서 처음 드러났다. **왜 못 걸렀나:** 쓸 때는
  날짜가 보관 기간 안이라 통과했고, 넣기의 결과(`insert`의 Bool)를 확인하지 않아 원인 대신 결과(표시등)에서 실패했다.
  수정: 소식을 제품과 같은 `TeamEventFactory.make(now: Date())`로 오늘 날짜에 만들고, 넣기가 받아들여졌는지 먼저
  확인한다. 부류 스윕: 고정 날짜 소식을 넣는 다른 테스트(`TeamSessionTests`, `TeamHostilePeerTests`,
  `PlazaBoardTests`의 목록 테스트)는 모두 저장소에 고정 시계를 준다. 나머지 광장 테스트는 세션이 오늘 날짜로 만드는
  소식만 쓴다.

- **누가 대상으로 잡히는지에 기대는 광장 테스트는 메타몽을 직접 통제한다.** 테스트가 만든 `PlazaWindowController` 는
  호스트라서 메타몽을 직접 띄우고, 무작위 칸에서 시작해 실시간 50ms 루프로 돌아다닌다. v2.5.632 릴리스 게이트에서
  `testWhileFocusingMyMenuHasNoTackleOrFollow` 가 한 번 `[.tackle]`(메타몽 메뉴)로 실패했다: 스페이스를 누를 때 메타몽이
  바라보는 칸 (10,11)에 서 있었고, 바라보는 칸이 옆 칸의 팀원보다 먼저다. **왜 못 걸렀나:** 사전 조건이 `isWalkable(beside)`
  뿐이라 "그 칸 말고 다른 대상이 없다"를 확인하지 않았고, 메타몽이 하필 거기 설 확률이 작아 재실행(6회)은 모두 통과했다.
  수정: `ParkedDitto`(루프를 재우고 시드로 먼 칸에 세움)를 대상이 걸린 광장 테스트의 컨트롤러에 넘기고, 팀원 옆에서 메뉴를
  여는 테스트는 팀원을 바라본 뒤 누른다. 가드: `testFacingTheTeammateOpensTheirMenuWithTheDittoAhead` 가 `ParkedDitto.seed(landingOn:)`
  로 메타몽을 바라보는 칸에 강제로 세운다(결함 주입 시 실패 확인). 스윕: `PlazaFocusTests`·`PlazaCardTests`·`PlazaBoardTests`·
  `PlazaPhotoModeTests`·`PlazaSnowballControllerTests`·`PlazaPrayTests`·`PlazaActivityControllerTests`·`PlazaEmoteTests`·
  `PlazaWindowTests`(연못 하네스). `Ditto`·`Mimic`·`PullUnder`·`Startle` 컨트롤러 테스트는 이미 루프를 재우고 시드를 준다.

- **새 SDK에서 통과해도 CI의 AppKit Sendable 선언을 가정하지 마라.** 동시 캐시 로드 테스트가
  `Task { await SpriteLoader.image(...) }` 로 `NSImage?` 를 반환해 로컬 Swift 6.3.3에서는 통과했지만,
  CI의 Xcode 16.4/Swift 6.1.2에서는 `NSImage: Sendable` 이 unavailable이라 테스트 컴파일이 실패했다.
  **왜 못 걸렀나:** 로컬 최신 도구체인으로 전체 테스트와 경고 검증을 해도 CI SDK 호환성을 검증한 것은 아니다.
  → 포켓몬·아이템 두 동시 로드 테스트 모두 `Task<Void, Never>` 를 사용하고 이미지 결과는 `@MainActor`
  안에 보관한다. 객체 동일성 검증과 동시 요청은 유지하며, Sendable 우회 선언을 추가하지 않는다.
  회귀 가드: `SpriteImageCacheTests` 의 두 동시 로드 테스트와 `macos-15` CI의 테스트 컴파일.
  (CI 실패: 2026-09-10.)
  **재발(2026-11-02, 팀 광장 PR):** 비격리 `PlazaSpriteFetching` 과 `PlazaIconLoader.icon` 이 `@MainActor`
  호출부·`SpriteLoader` 사이로 `NSImage` 를 넘겨 Xcode 16.4/Swift 6.1.2 소스 컴파일이 8건 실패했다.
  Xcode 26.5 SDK 에서는 `NSImage` 가 Sendable 이라 로컬 전체 테스트가 통과한다.
  **왜 못 걸렀나:** 포크는 워크플로가 꺼진 채로 시작해 PR 을 열 때까지 `macos-15` CI 가 한 번도 돌지 않았다.
  `swift build` 는 테스트 타깃을 컴파일하지 않아, `NSImage` 를 저장한 `Sendable` 테스트 더블도 소스 오류 뒤에
  숨어 있었다. → `NSImage` 를 주고받는 async API 는 호출부와 같은 `@MainActor` 에 두거나, `SpriteLoader` 처럼
  격리 경계는 `Data` 로 넘고 `NSImage` 는 메인 액터에서 만든다. 프로토콜에 `@MainActor` 를 두면 구현체와
  테스트 더블까지 함께 격리된다. 포크·새 저장소는 PR 을 열기 전에 Actions 부터 켠다.
  테스트 타깃은 `XCTestCase` 격리도 다르다: Xcode 16.4 에서는 `@MainActor` 테스트의 `await super.setUp()` 이
  `self` 전송 오류이고, 동기 `setUp`/`tearDown` 은 비격리라 격리된 프로퍼티를 만지지 못한다. 저장소 관용구대로
  `await super` 호출을 두지 않고, 동기 override 가 쓰는 프로퍼티는 `nonisolated(unsafe)` 로 둔다.
  컴파일은 오류가 나면 일찍 멈춰서 CI 가 `await super` 2개 파일만 보고했지만 실제로는 6개 파일에 있었다.
  CI 가 알려 준 파일이 아니라 패턴으로 스윕한다.
  CI 러너는 영어 로케일이라 한국어 이름을 단언하는 테스트는 `setLanguage(.ko)` 로 언어를 고정한다. 한국어 Mac 에서는
  `xcrun xctest -XCTest <모듈.스위트> -AppleLanguages '(en)' <.xctest 번들>` 로 재현된다.
  로컬 재현은 도구체인 조합에 달려 있다: 이 Mac 의 CLT(Swift 6.0.3)는 `SwiftBridging` 모듈 중복으로
  `Foundation` 을 못 읽고, Xcode 26.5 컴파일러에 15.2 SDK 를 붙이면 `@Observable` 매크로가 맞지 않는다.
  **재발(2026-11-05, 사진 모드 PR #67):** 새 `@MainActor` 테스트가 동기 `override func setUp() { clockTime = 0 }` 로
  격리된 `var` 를 되돌려 CI(Xcode 16.4/Swift 6.1.2)의 테스트 컴파일이 실패했다. 로컬 Xcode 26.5(Swift 6.3.2)는 통과시킨다.
  **왜 못 걸렀나:** 위 규칙이 문장으로만 있어 계획의 전역 제약에도 과제 리뷰에도 들어가지 않았고, 로컬 전체 테스트와
  게이트는 최신 도구체인이라 이 부류를 볼 수 없다. → 소스 스캔 가드 `TestIsolationTests` 가 `@MainActor` XCTestCase 의
  동기 `setUp()`/`tearDown()` 본문이 `nonisolated(unsafe)` 가 아닌 클래스 멤버(`var`·`func`)를 쓰면 실패한다.
  그 줄은 지웠다(XCTest 는 테스트마다 새 인스턴스를 만들어 초기값이 이미 0이다). 부류 스윕: Tests 의 동기 override 전부를
  가드로 검사했고 위반은 이 한 곳뿐이었다. 가드는 이 줄을 되살리면 실패한다(주입 확인).
  **가드 자체의 보강(2026-11-05, PR #67 점검):** 처음 스캐너는 ① 줄마다 앞의 비지 않은 줄을 다시 만들어 파일당 O(n²)(실행당 6초)였고
  ② `setUpWithError()`/`tearDownWithError()` 를 안 보고 ③ `private(set) var` 를 멤버로 못 세고 ④ 문자열·주석 안의 `{` 로
  깊이가 틀어졌다. 앞 줄을 한 번에 적어 선형(0.28초)으로 만들고 세 경우를 `testTheScanFlagsIsolatedMembersOnly` 에 더했다
  (각 규칙을 되돌리면 실패). 실제 테스트 파일에는 새 위반이 없다.
  **재발(2026-11-06, 팀원 목록 페이지 PR #77):** 새 `@MainActor` 테스트의 `try await super.setUp()` 이 CI(Xcode 16.4)에서만 컴파일 실패했다.
  **왜 못 걸렀나:** 이 금지는 위에 문장으로만 있었고, 가드는 동기 override 만 봤다. 로컬 게이트가 통과해 PR 전에 이 절을 다시 볼 이유도 없었다.
  → `TestIsolationTests.testNoTestAwaitsSuper` 가 `await super.` 를 스캔한다(줄을 되살리면 로컬에서 실패, 주입 확인). 스윕: 전체에서 이 한 곳이었다.
- **SwiftUI `View`/`App` 경계는 `@MainActor` 를 명시한다.** Swift 6.3 은 `body` 밖의 `@ViewBuilder` helper·
  동기 클로저를 nonisolated 로 검사해, `@MainActor` `@Observable` store 접근이 수십 개의 오류로 연쇄된다.
  개별 프로퍼티에 `MainActor.assumeIsolated` 를 흩뿌리지 말고 UI 타입 선언 한 곳에 격리를 둔다.
  `SwiftUIIsolationTests.testEverySwiftUIViewAndAppIsMainActorIsolated` 가 새 View/App 선언 누락을 소스 스캔으로 막는다.
- **coverage profile producer와 consumer는 같은 LLVM toolchain이어야 한다.** Homebrew Swift 6.3 이 만든
  `default.profdata` 를 구형 Xcode의 `xcrun llvm-cov` 로 읽으면 `unsupported instrumentation profile format
  version` 으로 테스트 성공 뒤 게이트만 실패한다. `test-gate.sh` 는 현재 `swift` 실경로 옆의 `llvm-cov` 를
  우선하고, sibling이 없는 Apple toolchain에서만 `xcrun --find llvm-cov` 로 폴백한다.
- **배포 바이너리는 빌드 호스트 아키텍처를 따라가지 않게 명시적으로 universal 로 만든다.** v2.5.4 는
  `build-app.sh` 의 아키텍처 미지정 `swift build -c release` 가 Apple Silicon 호스트의 arm64 만 패키징해,
  README 가 지원한다고 적은 Intel Mac 에서 `bad CPU type in executable` 로 실행조차 안 됐다(#358).
  **왜 못 걸렀나:** CI·로컬 테스트·release.sh 게이트 모두 arm64 호스트에서만 돌아 결과 바이너리의 아키텍처를
  확인하는 단계가 없었다. `swift build --arch arm64 --arch x86_64` 는 xcbuild(Xcode)가 필요해 CLT 환경에서
  실패하므로, 아키텍처별 빌드 + `lipo -create` 로 합친다. 회귀 가드: `build-app.sh` 의 `lipo -verify_arch`
  와 release.sh 4/8 의 `lipo -verify_arch arm64 x86_64` 하드 게이트(릴리스는 `PTB_NATIVE_ARCH_ONLY` 금지).

- **원본 릴리스의 게이트를 포크 스크립트로 옮길 때 빠뜨리지 않는다.** `team-release.sh`는 `release.sh`와 달리
  `test-gate.sh`를 돌리지 않아, CI가 실패하거나 건너뛴 `main`도 팀 전체에 배포될 수 있었다. **왜 못 걸렀나:**
  `testTeamReleaseChecksRunBeforeTheBuild`의 목록이 스크립트에 있는 확인만 나열해서, 없는 확인은 드러나지 않았다.
  서명 확인 뒤, 빌드 앞에서 돌린다. 가드: 같은 테스트의 체크 목록.
  설치 경로도 마찬가지다. 원작 cask의 `xattr -cr` 단계가 빠진 채 zip 설치로 바꾸자 팀원 Mac에서 Gatekeeper가
  앱을 막았다. 자체 서명 앱이라 공증이 없고, 원작은 cask가 격리 표시를 지워서 경고가 보이지 않았을 뿐이다. 이 Mac은
  직접 빌드해서 격리 표시가 없으므로 재현되지 않는다. 팀 탭 cask의 `postflight_steps`가 같은 일을 한다.
  **Windows 게이트도 같은 한 번의 릴리스에 들어 있다. Mac 만 나가는 릴리스는 없다.** `team-release.sh` 는 두 OS 의 게이트가
  모두 통과해야 공개하고(`team_release.py publish` 는 zip 과 설치 파일 둘이 없으면 거절한다), 한쪽이 실패하면 아무것도
  공개되지 않는다. 가드: `TeamReleaseScriptTests` 의 단계 순서 시험(publish 한 줄, collect 가 publish 앞)과
  `TeamReleaseScriptRunTests`(Windows 실패 시나리오).

- **움직이는 ref 로 릴리스를 빌드하지 않는다.** 릴리스는 검증한 커밋 SHA 하나에서만 만든다. Windows 빌드를 `main`
  같은 가변 ref 로 돌리면, 릴리스를 시작한 뒤 병합된 커밋이 설치 파일에 섞이고 Mac zip 과 다른 코드가 같은 버전으로 나간다.
  **왜 못 걸렀나:** 일반 CI 실행은 "그때의 main" 을 빌드하는 것이 정상이라, 릴리스 실행이 그 규칙을 따르는지 보는 시험이 없었다.
  가드(stage 8 Task 1): 릴리스 모드 워크플로는 `release_sha`·`release_version` 입력을 받고 첫 단계 "Release pin" 이 체크아웃이
  그 커밋이 아니거나 `VERSION` 이 그 버전이 아니거나 워크플로 파일이 디스패치한 ref 와 다르면 실패한다. 릴리스 실행은 자기
  동시성 그룹(`<workflow>-release-<sha>`)에서 돌고 푸시로 취소되지 않으며, 산출물 `windows-release` 에는 커밋·버전·게이트
  결과·해시가 들어간다. `team_release.py collect` 가 매니페스트의 sha 와 해시를 확인한다.

- **릴리스 단계가 clone 안에 파일을 남기면, 같은 clone 에서 다시 실행할 때 깨끗한 트리 확인에서 멈춘다.** stage 8의
  `team-release.sh` 가 1단계에서 `python3 -m unittest discover -s scripts/tests` 로 도우미를 시험하자 Python 이
  `scripts/__pycache__/`·`scripts/tests/__pycache__/` 를 만들었고(무시 목록에 없다), 실제 리허설(새 clone, 52분) 뒤 같은
  clone 에서 다시 실행하자 0단계 `git status --porcelain` 에서 "커밋하지 않은 변경"으로 멈췄다. 실패 뒤 고치고 다시 실행하는
  것이 이 스크립트의 정상 흐름(Windows 실행 실패, 노트 수정)이라 릴리스를 막는다. **왜 못 걸렀나:** 스크립트 테스트의 가짜
  `python3` 는 아무것도 쓰지 않고 가짜 `git status` 는 정해 준 값만 돌려줘서, 다시 실행 테스트가 진짜 부작용이 없는 다른
  경로로 통과했다. 리허설 뒤 clone 의 `git status` 를 보고 찾았다. 수정: 스크립트가 `PYTHONDONTWRITEBYTECODE=1` 을 export 한다.
  가드: 가짜 `python3` 가 그 변수가 없으면 진짜처럼 `scripts/__pycache__/` 를 쓰고 가짜 `git status` 가 그것을 보고하므로,
  `TeamReleaseScriptRunTests` 의 다시 실행 테스트가 export 없이는 실패한다(결함 주입으로 확인). 스윕: 다른 단계가 쓰는 곳은
  무시되는 `build/`(start 의 runs.json, collect, fill, build-app.sh)와 `.build/`(test-gate.sh)뿐이다.

- **한 줄씩 읽는 목록·설정 파일에서 값 뒤의 `# 주석`은 파서가 떼지 않으면 주석이 아니다.** 윈도우 이식의 테스트용
  `mac-only.txt` 에 `BinaryLocatorTests.swift  # 이유` 처럼 적었더니 한 줄 전체가 파일명이 되어 그 파일이 제외되지
  않았다(조용히). 파서는 전체 줄 주석(`#` 로 시작하는 줄)만 안다. **왜 못 걸렀나:** 제외 목록은 "있는 것만 빼는"
  구조라 틀린 항목이 에러 없이 무시됐다. 잡은 것은 `SharedSourcesScanTests.testEveryListedPathExists`(목록의 모든 경로가 실제로
  있어야 함)였다. **규칙:** 목록·설정 파서의 주석 문법을 파일 머리에 적고 그 밖의 형태는 쓰지 않는다. 목록의 항목이 가리키는
  것이 실제로 있는지 확인하는 테스트를 둔다(없는 항목이 조용히 무시되는 목록에는 필수).

- **윈도우의 Foundation은 같은 API를 조용히 다르게 돌린다 (타이머·검색 경로·번들·defaults) — 첫 항목: `Timer(timeInterval:repeats:block:)` 는 윈도우에서 즉시 한 번 발화한다.**
  swift-corelibs-foundation 은 이 생성자를 `init(fire: Date(), …)` 로 구현해, 맥(첫 발화가 간격 뒤)과 달리 윈도우에서는 만드는 즉시
  첫 틱이 온다(E1 실측: 윈도우 8 ms, 맥 1009 ms). 공용 `UsageStore.reschedule()` 은 기동·간격 변경마다 즉시 갱신을 한 번 더 돌리고(`autoRefresh` 면
  기동 때 이중 갱신), `suspendPolling()` 의 프로브는 300 초 뒤가 아니라 디스플레이가 꺼지자마자 로그를 파싱한다. **왜 못 걸렀나:** 맥에서는
  옛 생성자가 항상 옳게 동작해 어떤 테스트도 실패하지 않았고, 타이머의 *첫 발화 시점*을 기다려 보는 테스트가 없었으며 윈도우 스위트는
  주입한 프로바이더로 타이밍을 재지 않았다. **규칙:** 공용·윈도우 코드는 `Timer(timeInterval:…)` 대신
  `Timer(fire: Date(timeIntervalSinceNow: i), interval: i, repeats: …)` 를 쓴다(`Timer.scheduledTimer(withTimeInterval:)` 은 양쪽 모두 간격 뒤라 무방).
  **가드(기계):** `WindowsSeamScanTests.testNoTimerIntervalInitializerInSharedOrWindowsCode` 가 `mac-only.txt` 밖 모든 소스의 해당 생성자를
  실패시키고(맥에서 옛 생성자를 되돌리면 이 스캔이 실패 — 결함 주입으로 확인), `UsageStoreTimerTests.testPollingTimerFirstFiresAfterTheInterval`
  이 양쪽 OS 에서 첫 발화가 간격 뒤임을 고정한다(윈도우에서 옛 생성자는 실패 확인). 스윕: `Sources/` 의 `Timer(timeInterval:` 4 곳 중 `UsageStore` 2 곳만
  공용이라 고쳤고 `PokeTokenBarApp`·`Team/TeamTransport` 는 맥 전용(`mac-only.txt`)이라 그대로다. 이 부류의 다음 항목(defaults)은 해당 작업이 이 항목 아래에 더한다.
  **검색 경로·번들(Task 3):** 윈도우에서 `urls(for: .libraryDirectory)` 는 매핑이 없어 `[]` 이고(`.applicationSupportDirectory` 는 `%LOCALAPPDATA%`, 슬래시 `/` 구분),
  `Bundle.main.bundleIdentifier` 는 항상 nil 이라 `AppEnv.isBundledApp` 이 늘 false 다. `AppLog` 의 `[0]` 은 첫 로그에서 트랩인데, `write` 가 번들 밖에서
  일찍 돌아와 가려져 있었다 — 같은 게이트가 저장·라이브 한도까지 조용히 껐다. **왜 못 걸렀나:** 맥에서는 두 호출이 항상 옳았고, 윈도우에서는 게이트가
  닫혀 로그 경로 계산에 닿지 않았다(게이트를 열면 비로소 도달 가능). **규칙:** 로그 폴더는 `PlatformCompat.logsDirectory()`, 번들 판정은
  `PlatformCompat.isBundledApp`(윈도우: exe 옆 `PokeTokenBar.version` 이 비어 있지 않을 때), 윈도우 셸 API 에는 `WinPath.native`, 경로 비교는 `WinPath.sameFile`.
  **가드(기계):** `WindowsSeamScanTests.testSharedFilesDoNotAskForTheLibraryDirectory`(결함 주입으로 실패 확인), `PlatformCompatTests` 가 맥의 옛 값을 고정,
  `WindowsFoundationTests` 가 러너에서 실제 동작을 단언. 스윕(`urls(for:in:)[0]`): `.applicationSupportDirectory` 6곳은 매핑돼 안전, `AppLog` 는 고침,
  `CrashReporter` 는 맥 전용(`mac-only.txt`)이라 그대로, `NSHomeDirectory()` 는 `BinaryLocator`·`PlatformCompat` 에서 정규화돼 쓰이며 하드코딩 `/Library/`·`/tmp` 는 공용 소스에 없다.
  **defaults(Task 5):** 윈도우의 `UserDefaults` 는 `set` 이 메모리만 바꾸고 디스크(`<프로필 폴더>\<사용자 이름>\AppData\Local\<프로세스 이름>.plist`,
  프로세스 이름에 `.exe` 포함)에는 `synchronize()` 때만 쓴다. `TerminateProcess` 는 물론 정상 `exit(0)` 에서도, 타이머로도 저장되지 않는다(E1 P9).
  맥은 cfprefsd 가 알아서 저장하므로 공용 코드 어디에도 `synchronize` 가 없고, 그대로면 설정과 `team.memberID` 가 매 종료마다 사라진다.
  **왜 못 걸렀나:** 맥 테스트는 cfprefsd 가 저장해 주는 환경이고, 윈도우 스위트는 한 프로세스 안에서 쓰고 읽어(메모리 캐시) 디스크를 보지
  않았으며, 앱 실행 파일이 없어 "끄고 다시 켜기" 를 할 대상이 없었다. **규칙:** 윈도우 앱은 공용 init 의 `defaults:` 에 `WinSyncingDefaults`
  (쓰기마다 2 초 뒤 저장)를 넣고, 30 초 안전 저장·스토어 생성 직후 저장을 두며, 프로세스는 `WindowsApp.exit` 로만 끝낸다(먼저 저장한다).
  **가드(기계):** `WindowsSeamScanTests.testWindowsCodeExitsOnlyThroughWindowsAppExit`(`Platform/Windows/**` 의 다른 `exit(`·`ExitProcess(`·
  `TerminateProcess(GetCurrentProcess` 를 실패시킨다, 주입 테스트 포함), `WindowsShellTests.testSyncingDefaultsSeesTypedSetters`(타입별 setter 도 저장
  예약에 닿음, G-i), 셀프테스트의 자식 프로세스 검사 `defaults.persist.debounce`·`defaults.persist.restart`(쓰고 3 초 뒤 강제 종료 → 새 프로세스가
  읽음)·`defaults.persist.exit`·`exit.closeRequest`·`exit.endSession`·`defaults.control`(정상 `exit(0)` 은 여전히 잃는다는 대조), 그리고
  `windows-app` 의 전체 앱 kill 단계. 스윕: 공용 소스의 `synchronize(` 호출은 0 곳(맥은 필요 없음)이고, 공용 코드가 `.standard` 에 직접 쓰는 곳도 없다
  (`BinaryLocator`·`KeychainAccessGate`·`CompanionStore` 는 읽기만 한다). 앞으로 생길 직접 쓰기는 30 초 안전 저장이 덮는다. 설정 파일 이름이 exe 이름에 묶이므로 배포 exe 이름(`PokeTokenBar.exe`)은 고정이다.
  **메인 스레드·메시지 펌프(Task 5):** 윈도우에서는 `RunLoop.main` 을 창보다 먼저 만져야 CF 가 Win32 메시지를 펌프하고(늦으면 그 창은 메시지를
  못 받고 스레드 간 `SendMessageTimeoutW` 가 막힌다), `async` main 은 첫 `await` 뒤 메인 액터 코드를 풀 스레드로 옮기며 창을 잃고, CF 의 펌프는
  ANSI 라 코드 페이지 밖 문자(예: U+D55C)가 `?` 로 온다(E1 P2, P6, TEXT). **규칙:** `main.swift` 는 동기, `WindowsApp.main()` 은 첫 줄에서
  `RunLoop.main` 을 만지고, 스레드 로컬 `WH_GETMESSAGE` 훅이 유니코드 창의 문자 메시지를 `DispatchMessageW` 로 다시 보낸다. 풀 스레드 콜백
  (`Platform/Windows/Team/**`)은 `DispatchQueue.main.async` 블록 안에서만 `MainActor.assumeIsolated` 를 쓴다. **가드(기계):**
  `testWindowsMainIsSynchronous`·`testNoAssumeIsolatedInPoolThreadCallbacks`(각각 주입 테스트 포함)와 셀프테스트 `loop.*`(스레드 id·지연·
  `SendMessageTimeoutW`·게시/입력한 U+D55C 가 그대로 도착) — XCTest 는 런루프를 제 방식으로 돌리므로 이 검사는 배포 루프 안에서만 의미가 있다.
  **메인 스레드의 파일 쓰기(Task 5 관찰 → 수정됨):** 윈도우의 FoundationEssentials `Data.write(to:options: .atomic)` 은 임시 파일을
  `FlushFileBuffers` 로 디스크까지 내린 뒤 바꿔 넣는다(맥은 fsync 하지 않는다). `@MainActor` 인 `CompanionStore.save()`(기동 갱신 한 번에 11 회)와
  `UsageStore.writeParitySnapshot()`(2 회)이 이를 메인 스레드에서 불러 러너에서 메인 스레드가 한 번에 146–231 ms 멈췄다(스톨 프로브: 17 개 표본
  모두 `ZwFlushBuffersFile` ← `FlushFileBuffers` ← `Data.write(to:options:)`). **왜 못 걸렀나:** 맥에서는 같은 쓰기가 짧고, XCTest 는 메인 스레드
  지연을 재지 않는다. **수정:** `PlatformCompat.atomicWrite` — 맥은 예전 호출 그대로, 윈도우는 같은 폴더의 임시 파일에 쓴 뒤 `MoveFileExW(REPLACE_EXISTING)`
  로 바꿔 넣는다(flush·WRITE_THROUGH 없음. `ReplaceFileW` 는 대상이 있어야 하고 쓰지 않는 속성·ACL 병합을 해서 고르지 않았다). 내구성은 맥과 같다:
  전원이 끊기면 마지막 저장은 잃을 수 있어도 이전 파일은 온전하다. **스윕:** `.atomic` 쓰기 20곳 — 메인 액터인 `CompanionStore.save`·`UsageStore.writeParitySnapshot`·
  `TeamFeedStore.save`·`SaveSnapshotManager.createSnapshot`(`update` 끝의 `autoSnapshotIfNeeded` 가 12 시간마다 메인 액터에서 부른다. 처음엔 "드물고 사용자가 시작"이라 잘못 분류했다: 호출자를 따라가야 한다)를 옮겼고(각 한 줄), actor 캐시(`LocalUsageCache`·`SpriteStore`·`PokeAPIClient`·`PokemonNameClient`)·드물고 사용자가 시작하는 쓰기
  (`CompanionStore.backupStateBeforeImport`)·자격증명 파일(`SessionKeyLimitsProvider`, 0600 보장이 먼저)·맥 전용(`CrashReporter`, `PlazaIconLoader`)은 그대로 뒀다.
  **가드(기계):** `AtomicWriteTests`(양쪽: 왕복·교체·임시 파일 없음·동시 쓰기자), `WinAtomicWriteTests`(주입한 실패 뒤 이전 파일 유지), `WindowsSeamScanTests.testMainActorStoresWriteThroughPlatformCompat`,
  셀프테스트 `loop.mainThreadStalls`(FlushFileBuffers 안의 표본이 하나라도 있거나 1000 ms 넘으면 실패. 수정 뒤 8 회 기동은 프로브 하한 30 ms 미만이었으나 이후 실행에서 로그 쓰기·파일 열기에 157·221 ms 가 한 번씩 나왔다(디스크 지연, flush 아님): 시간 상한만으로는 잡음에 걸리므로 원인을 이름으로 잡는다. 전에는 231·146 ms). **규칙:** 메인 액터나 갱신 경로의 파일 쓰기는 `PlatformCompat.atomicWrite` 로.
  **설정 plist(같은 부류의 반대편):** CF 는 plist 를 제자리에 쓴다(임시 파일·rename 없음, `CFURLWriteDataAndPropertiesToResource`; corelibs `CFXMLPreferencesDomain.c` 로 확인).
  읽을 때 파싱이 3 번 실패하면 **빈 사전**을 쓰므로, 쓰는 도중 kill·정전이 나면 다음 동기화가 바뀐 키만 써서 모든 설정과 `team.memberID` 가 사라질 수 있다. 3 s 뒤 kill 하는 CI 테스트는
  쓰는 도중을 못 친다. **수정:** `SettingsPlistGuard` — 동기화 뒤 plist 가 파싱될 때만 `<plist>.bak` 를 `atomicWrite` 로 남기고, 기동 시 첫 읽기 전에 없거나 파싱 안 되면 백업을 되돌린다
  (멀쩡한 plist 는 옛 백업으로 덮지 않는다). `synchronize()` 가 false 면 한 번 로그. 셀프테스트는 자기 suite 를 써서 실제 `PokeTokenBar.exe.plist` 를 건드리지 않는다.
  **Observation 재수출(Track A Task 12):** 맥의 Foundation 은 Observation 을 다시 내보내 `withObservationTracking`·`@Observable` 이
  `import Observation` 없이도 빌드되지만, 윈도우의 corelibs Foundation 은 내보내지 않는다. 공용으로 옮긴 `PlazaWindowController` 가 윈도우에서만
  `cannot find 'withObservationTracking' in scope` 로 실패했다. **왜 못 걸렀나:** `shared-check.sh` 는 공용 집합을 맥의 Foundation 으로
  빌드하므로 재수출이 그대로 보인다. **가드(기계):** `WindowsSeamScanTests.testSharedFilesThatObserveImportObservation`(고치기 전 트리에서
  실패 확인). 스윕: `withObservationTracking` 을 쓰는 소스 4곳 중 공용은 `TeamRuntime`(이미 import)과 이 컨트롤러뿐이고, `@Observable` 을 쓰는
  공용 파일은 모두 `import Observation` 이 있다(스캔이 확인).
  **COM 아파트(Stage 6 Task 2, S10):** 윈도우 앱은 UI 스레드(프로세스 메인 스레드)의 COM 아파트를 어디서도 정하지 않았다. `CWinShim` 의 WIC 호출은 호출한
  스레드에서 `CoInitializeEx(MTA)` 를 하고 끝나면 `CoUninitialize` 하므로(트레이 아이콘 디코드가 메인 스레드에서 돈다), 그 스레드는 평소 아파트 없음/묵시적 MTA 이고
  첫 WIC 호출 동안만 MTA 다. 한글 IME(TSF)·이모지 패널·드래그 앤 드롭은 창을 소유한 스레드가 STA 이기를 기대한다. **왜 못 걸렀나:** 어떤 검사도 아파트를
  읽지 않았고(`tray.icon` 은 디코드가 *되는지*만 본다 — MTA 든 STA 든 WIC 는 돈다), 입력 쪽 결함은 IME 로 한글을 칠 때 비로소 보이는데 그 경로는 PC 에서만 돈다.
  **수정:** `WindowsApp.main` 의 첫 줄이 `ptb_com_init_sta`(`CoInitializeEx(STA | DISABLE_OLE1DDE)`)를 부른다. `CPlazaD2D` 의 WIC 는 스레드마다 처음 한 번 MTA 를
  얻고(이미 STA 인 메인 스레드는 `RPC_E_CHANGED_MODE` 라 그대로 쓴다), shim 의 옛 호출도 같은 이유로 STA 에서 계속 동작한다. **가드(기계):** 셀프테스트
  `com.uiThreadSTA`(기동 직후·초기화 뒤·트레이 디코드와 WIC 디코드 뒤의 `CoGetApartmentType` 을 한 줄에 — STA 또는 main STA 여야 통과; 첫 STA 는 main STA 로 보고된다),
  `com.workerThreads`(새 스레드에서 두 경로가 되고 스레드가 끝난 뒤에도 메인이 STA), XCTest `testAThreadThatIsAnSTAStillDecodes`/`testAThreadWithoutCOMGetsAnMTAFromTheCodec`.
  **스윕:** `Sources/` 의 `CoInitializeEx` 는 `CWinShim/wic.cpp` 2곳(둘 다 MTA 요청 뒤 성공했을 때만 `CoUninitialize`, `RPC_E_CHANGED_MODE` 는 무시)과 `CPlazaD2D` 뿐이고,
  `CoCreateInstance` 는 모두 WIC 팩토리다. COM 을 쓰는 다른 호출(`Shell_NotifyIconW`, 레지스트리, 소켓)은 아파트가 필요 없다.

- **윈도우 URLSession 은 새 연결의 전송이 끝날 때까지 디스패치 스레드 둘이 서로를 깨운다 (상태 확인 버스트, 유휴 게이트 간헐 실패).**
  **증상:** `windows-port` 의 유휴 게이트(설치 앱, 300 s 창에 스토어 갱신 2 회)가 간헐 실패했다 — 7209 cs/분(예산 4000; 이전 4 회 1568–2598). 갱신(120 s)마다
  15 s 조각 하나에서 디스패치 스레드 하나가 4500–8000 회 깨어났고, 프로바이더 상태 확인을 끄면 33–44 회였다. CPU 는 작았다(300 s 에 0.5 s).
  **원인(업스트림 소스로 확인, swift-6.3.2-RELEASE):** corelibs `FoundationNetworking/URLSession/libcurl/MultiHandle.swift` 는 curl 소켓을 디스패치
  소스로 감시한다(윈도우는 `makeReadSource/makeWriteSource(handle:)`, 527–549행). `register`(110–140행)는 curl 이 관심을 바꿀 때 없는 소스만 만들고,
  두 소스를 함께 치우는 건 `CURL_POLL_REMOVE`(125–131·551–577행)뿐이다 — 연결(connect)·TLS 때 만든 쓰기 소스가 curl 이 읽기만 원하게 된 뒤에도
  전송이 끝날 때까지 남는다. 윈도우 libdispatch(`src/event/event_windows.c`)는 소켓 쓰기 소스를 레벨 트리거처럼 흉내 내려고 다시 무장할 때마다
  0 바이트 `send()` 를 하고 성공하면 곧바로 "쓰기 가능" 을 IOCP 에 올린다(487–505행; 재무장은 `_dispatch_unote_resume_muxed`, 581–588행).
  연결된 소켓은 늘 쓰기 가능하므로: 발화 → `performAction` → `curl_multi_socket_action(socket, 0)`(MultiHandle 288–303행), 쓸 것 없음 → 재무장 → 0 바이트
  `send` 성공 → 발화 … 이벤트 루프 스레드(`GetQueuedCompletionStatus`)와 루트 큐 워커 사이를 전송 내내 오간다. **새 연결에서만** 생긴다: 재사용된
  keep-alive 연결은 curl 이 쓰기 관심을 묻지 않아 조용하다(루프백 2 s 대기: 새 연결 2027 ms 내내 41,104 회/s, 프로세스 167k cs·4.1 G 사이클 /
  재사용 48 cs; 10 s 대기 843k cs; 8 MB 를 한 번에 받기 1,035 cs — 양이 아니라 기다린 시간에 비례한다).
  앱의 120 s 갱신은 libcurl 의 유휴 연결 재사용 한도 118 s(curl 8.9.1 `url.c` 481행 `maxage_conn = 118`, 722–733행; corelibs 는 바꾸지 않는다)를 넘겨
  매번 새로 연결한다. 실측(러너): 앱의 상태 확인 경로(두 호스트 동시, 새 연결) 한 번 18,811 cs·478 M 사이클(369 ms), status.openai.com 한 번
  6–20k cs(142–279 ms); XCTest 프로세스에서 2 s 응답을 1.5 s 기다리는 동안 가장 바쁜 스레드 42–71k cs. 스택 표본 150 개 중 3–6 개가 `dispatch.dll`
  이 부른 `WS2_32!send`(curl 은 보낼 게 없다), 짝 워커는 `dispatch_semaphore_wait` 에서 깨어 `FoundationNetworking.dll` 을 거쳐 IOCP 에 다시 올린다.
  corelibs 의 10 s 요청 타임아웃은 멈춘 본문을 끝내지 못했다(서버가 20 s 에 닫아서야 끝남: 1.71 M cs·41.5 G 사이클) — 새 연결에서 응답이
  멈추면 버스트는 서버가 포기할 때까지 한 코어를 쓴다.
  **왜 게이트가 운으로 통과했나:** ① 버스트 양 = 러너에서 두 상태 호스트로의 새 HTTPS 전송 시간(DNS·TCP·TLS·서버 응답) × 루프 속도다. 앱 코드가 아니라
  네트워크 타이밍이 정하는 값을 4 회 표본의 1.5 배로 예산을 잡았고, 응답이 느린 run(갱신마다 한 스레드에 17.8k cs, 전송 0.4–0.7 s 에 해당)이 넘었다. ② 게이트(`measure-idle.ps1`)는 창 끝에 살아
  있는 스레드만 센다 — 짝 워커는 갱신마다 새로 생겼다 사라져(타임라인의 tid 8792→5540) 버스트의 절반가량이 보이지 않았다(사이클 합계는 죽은 스레드도
  포함한다). ③ 셀프테스트의 유휴 창은 갱신을 빼고 쟀고, 전송 한 번의 깨움을 재는 테스트가 없었으며, CI 픽스처에는 자격증명이 없어 같은 버스트를
  내는 한도 조회가 한 번도 돌지 않았다.
  **고침:** `PlatformCompat.oneShotData(for:)` — 맥은 `URLSession.shared.data(for:)` 그대로, 윈도우는 평범한 GET 을 자기 스레드에서 WinHTTP 동기 호출로
  보낸다(`Platform/Windows/WinHTTPFetch.swift`: 커널에서 블록, 폴링 없음). 요청은 같다: 헤더·`timeoutInterval`(resolve·connect·send·receive), Schannel
  인증서 검증 + 폐기 확인(curl Schannel 기본값, `schannel.c` 8.9.1 493–495행), gzip/deflate 해제, 리디렉션(WinHTTP 기본: 최대 10, HTTPS→HTTP 금지),
  크기 제한 없음(전과 같음), 직접 연결(corelibs 의 libcurl 도 윈도우 프록시 설정을 읽지 않는다). `http_proxy`·`https_proxy`·`all_proxy` 가 있으면
  libcurl 이 그걸 따르므로 URLSession 을 그대로 쓴다(POST 등·WinHTTP 로드 실패도). 업스트림 줄 하나: `ProviderStatusChecker.swift` `fetchOne` 의 호출.
  **같은 부류, 고치다 생긴 것:** 처음엔 WinHTTP 세션을 프로세스에 하나 두었더니 기동 때의 연결이 풀에 남아 스레드 풀 워커가 2–3 s 마다 깼다(갱신 없는
  120 s 창에서 43–59 회, 고치기 전엔 없던 스레드). 120 s 뒤의 다음 요청은 어차피 새로 연결하므로(libcurl 도 그랬다) 요청마다 세션을 열고 마지막에
  닫는다 — 그 창은 다시 두 스레드(libdispatch 1 Hz 쌍)뿐이다. 상태 확인 한 번: 129 cs·70 M 사이클(253 ms), 뒤 30 s 에 남는 것 없음.
  결과: 유휴 게이트 정상 300 s(같은 머리 d46c7b3 에서 연속 3 회, 같은 코드의 a78a992 1 회) 166–186 cs/분·1.39–2.03 M 사이클/s·CPU 0.14–0.20 s — 같은 날 `windows-port` 대조
  3 회는 2148–2620 cs/분·3.3–4.1 M·0.44–0.64 s(실패한 run 7209). 예산을 다시 잡았다: 정상 창 4000 → 280 cs/분, 6 M → 3 M 사이클/s(같은 코드 네 run 최악의
  1.5 배; 처음 잡은 2.75 M 은 넷째 run 의 2.03 M 에 여유가 1.35 배뿐이라 넓혔다; 주 스레드 30·메모리 5 MB·핸들 10 은 그대로) — 이런 갱신 하나(≥ 6k cs)면 그것만으로 실패한다. 갱신 없는 120 s 창은 이 결함과 무관해 Task 12 값
  그대로다(133–134.5 cs/분·198–214 k 사이클/s; 대조 125.5–126·167–174 k 에 WinHTTP 가 남기는 스레드 풀 깨움이 120 s 에 12–19 회 더해진다 — 시스템
  DLL 의 타이머로 6–10 s 에 한 번, 언로드 없이는 못 끈다). WinHTTP 로딩으로 비공유 메모리 +2.4 MB·핸들 +100 이 한 번 늘고(세션을 닫으면 핸들은 창 안에서 줄어든다) 그 뒤로 자라지 않는다.
  **규칙:** 윈도우에서 도는 코드는 URLSession 으로 직접 요청하지 않는다 — 모든 일회성 HTTP 는 `PlatformCompat.oneShotData(for:session:)` 또는
  `oneShotData(from:)` 로 보낸다(맥은 호출부가 쓰던 바로 그 URLSession 호출). 깨움을 잴 때는 창 안에서 끝난 스레드도 센다.
  **가드(기계):** `WindowsSeamScanTests.testNoRequestOutsideTheSeamInCodeThatRunsOnWindows`(직접 요청은 이음매·진단 도우미에만)·
  `testEveryRoutedSiteStaysOnTheSeam`(경유한 호출부마다 횟수 고정)·`testTheRequestScanCatchesEachForm`(첫 판의 세 스캔은 호출부를 URLSession 으로 되돌리고
  맥 분기를 ephemeral 세션으로 바꾸는 결함 주입으로 실패 확인), `OneShotDataMacTests`(맥 분기 셋: 공유 세션, 호출부 자신의 세션, `data(from:)`; `URLProtocol`
  스텁), `WindowsHTTPFetchTests`(대조군 URLSession 과 같은 답: 헤더·본문·리디렉션·압축·청크·10 MB·204/304·오류·취소·프록시, 그리고
  `testAWaitingTransferThroughTheSeamDoesNotKeepAThreadAwake`: 2 s 전송의 1.5 s 동안 가장 바쁜 스레드 < 150 cs, URLSession 대조군은 42–71k),
  `WindowsProxyRouteTests`(libcurl 의 프록시 변수 규칙), 다시 잡은 유휴 게이트 예산, 진단 `--selftest-net-burst`(`windows-app` 의 `net_burst` 입력).
  **스윕(후속, 같은 날):** 윈도우에서 도는 앱 코드의 직접 요청 14 곳(상태 확인 포함)을 모두 이음매로 옮겼다 — 한도(Claude 사용량·프로필, 세션 키,
  Cursor 토큰·사용량·한도, Grok, OpenCode Go: 갱신마다), 업데이트 피드 둘, PokeAPI 둘, 이름 표, 스프라이트 셋, 플라자 아이콘. 각 업스트림 줄은 한 줄 호출 교체다.
  스트리밍·웹소켓·백그라운드 세션은 없다. 맥 전용(`AntigravityRateLimitsProvider`, `PlazaIconLoader`)은 해당 없음. 같은 결함의 두 번째 공백:
  **CI 픽스처에 자격증명이 없어 갱신마다 도는 한도 조회가 게이트에서 한 번도 돌지 않았다**. Claude 한도 URL 은 업스트림의 `private static let` 이라
  루프백으로 돌릴 이음매가 없고 업스트림에 새로 만들지 않는다 — 그 요청 모양(헤더·토큰·타임아웃)을 셀프테스트(`--selftest-net-burst`)에서 잰다.
  측정(러너, 루프백, 200 ms 뒤 응답, run 43704153204): 호출부마다 요청 한 번 — URLSession(새 연결) 18,969–21,254 cs·390–406 M 사이클 → 이음매
  61–70 cs·6–8 M (Claude 사용량·프로필, 세션 키, Cursor 토큰·사용량·한도, Grok·OpenCode, 업데이트 피드, PokeAPI REST·GraphQL·이름). 바로 답하는
  스프라이트(40 KB)는 기다림이 없어 둘 다 55 cs. 윈도우 프록시 설정(`WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY`) 대 직접: 루프백 중앙값 2.3 대 0.9 ms,
  status.claude.com 32.1 대 29.3 ms, 프로세스 첫 요청 9.3 ms — 캐시는 두지 않는다(세션을 오래 두면 유휴 깨움이 돌아온다). 교차 세션 연결 풀을
  끄자(`WINHTTP_OPTION_DISABLE_GLOBAL_POOLING`) 갱신 없는 120 s 창이 112.5 cs/분(대조 125.5–126)으로, WinHTTP 가 남기던 스레드 풀 깨움이 사라졌다.
  **WinHTTP 가 libcurl 과 다르게 하던 것(루프백에서 URLSession 대조로 확인):** zlib 로 감싼 deflate 를 못 풀어(`E_ABORT`) gzip 만 요청한다; 수신
  타임아웃을 데이터가 올 때만 확인해 1 s 타임아웃이 5.4 s 걸렸다 → 요청 동안만 있는 우리 유휴 타이머가 끝낸다; 본문이 Content-Length 보다 일찍 끊겨도
  오류 없이 멈출 수 있어 길이를 대조해 `.networkConnectionLost` 로 알린다. 같은 것: 교차 호스트 리디렉션(Authorization 도 둘 다 넘긴다), 303 뒤 GET,
  청크·gzip·10 MB·204/304. 오류 코드(이음매/libcurl): 시간 초과 -1001/(libcurl 은 끝내지 못함), 중간 끊김 -1005/-1, 거부 -1004/-1001, 이름 없음
  -1003/-1003, TLS 실패 -1200/-1 — 공용 코드는 `NSURLErrorDomain` 도메인만 보고(`LocalizationErrors.swift` 7행) 호출부는 코드로 분기하지 않는다.
  **테스트의 가짜도 같은 부류다:** `URLProtocol` 스텁은 URLSession 만 본다. 이음매를 처음 넓혔을 때 `InstallerReleaseFeedTests` 가 스텁 대신 실제
  api.github.com 으로 나갔고(윈도우 CI), `ClaudeOAuthFileCredentialTests` 가 실패했다. 호출부 세션의 `protocolClasses` 에 자기 프로토콜이 있으면
  URLSession 을 쓰고(`WinHTTPFetch.handles`), 전역 등록 스텁(corelibs 는 목록을 내주지 않는다)을 쓰는 테스트는
  `PlatformCompat.oneShotStaysOnURLSessionForTesting` 을 켠다. **규칙 추가:** 네트워크를 바꾸는 이음매는 기존 가짜 경로가 여전히 가짜에 닿는지 윈도우 CI 에서 본다.
  **리뷰 라운드(같은 브랜치, 머지 전): 자격증명·로그온·본문 수명·핸들.** 독립 리뷰가 찾은 넷과 고침.
  ① **교차 호스트 리디렉션이 자격증명을 들고 갔다.** WinHTTP 자동 리디렉션(최대 20, HTTPS→HTTP 만 막음)은 요청 헤더를 전부 다시 보낸다 —
  `Authorization: Bearer …`, `Cookie: sessionKey=…`, `WorkosCursorSessionToken`. 공급자 호스트 하나의 오픈 리디렉트면 토큰이 제3자에게 간다.
  **왜 못 걸렀나:** 기준을 윈도우 URLSession(corelibs 는 리디렉션에 헤더를 모두 유지, `HTTPURLProtocol.swift` 564행)으로 잡고 맥과 비교하지 않았다.
  테스트(`…IncludingToAnotherHost`)는 Authorization 이 넘어가는지 **print 만 했다** — 단언이 아니라 출력이라 통과가 아무것도 지키지 않았다.
  **맥 실측(`RedirectHeadersMacTests`, 루프백 서버 둘):** 맥 URLSession 은 모든 홉(같은 출처 포함)에서 `Authorization` 을 빼고, 명시한 `Cookie`·사용자
  헤더는 교차 호스트에도 다시 보낸다(공유·쿠키 끈 ephemeral 세션 모두); 307 은 POST·본문 유지, 303 은 GET. **고침:** 리디렉션을 우리가 따른다
  (`WINHTTP_OPTION_REDIRECT_POLICY_NEVER`, `WinHTTPFetch.nextHop`): 홉마다 `Authorization` 제거(맥과 같음), `Cookie` 가 남은 요청은 다른 출처(스킴·호스트·
  포트)로 따르지 않고 3xx 를 돌려준다(맥보다 엄격; 호출부는 200 이 아니면 실패로 본다), HTTPS→HTTP 금지, 20 홉·루프 즉시 중단.
  ② **서버의 NTLM/Negotiate 401 에 윈도우 로그온이 나갈 수 있었다.** 기본 자동 로그온 정책 MEDIUM 은 "프록시 우회 목록의 서버"를 인트라넷으로 본다
  (`WinHttpRequestAutoLogonPolicy`, AutoLogonPolicy_OnlyIfBypassProxy) — 프록시가 없으면 어느 호스트든 우회다. libcurl 은 자격증명 없이 인증하지 않았으니
  새 능력이었다(NTLMv2 응답은 오프라인 크랙·릴레이 대상). **왜 못 걸렀나:** 문서의 "인트라넷만" 을 정의 확인 없이 믿었고, 401 로 도전하는 테스트 서버가
  없었다. **러너 대조(프록시 없음):** 이전 설정(인증 켬, MEDIUM)은 127.0.0.1·localhost 의 401 에 두 번째 요청으로 `Authorization: Negotiate` 를 보냈다 —
  리뷰의 추정대로다. **고침:** 모든 요청은 자동 인증 끔(`WINHTTP_DISABLE_AUTHENTICATION`) + 정책 HIGH 로 시작(HIGH 는 "localhost·IP 로 지정한 서버에는 효과가 없다"고
  문서에 적혀 있어 둘 다 건다). 요청이 지난 프록시(환경 변수 프록시, 또는 윈도우 설정에서 `WINHTTP_OPTION_PROXY` 가 이름을 대는 프록시)의 407 에만 한 번,
  새 요청을 MEDIUM 으로, 그래도 NTLM/Negotiate 를 요구하면 이름 없는 `WinHttpSetCredentials` 로 — .NET WinHttpHandler 와 같은 방식(dotnet/runtime v9.0.0
  `WinHttpAuthHelper.cs` 288–300·335–346, `WinHttpHandler.cs` 1517–1528).
  ③ **요청 본문 포인터가 `body.withUnsafeBytes` 안에서만 유효했다.** WinHTTP 는 `WinHttpReceiveResponse` 가 끝날 때까지(인증 라운드·리디렉션) 그 버퍼를
  다시 보낼 수 있다(`WinHttpSendRequest`: "must remain available until the request handle is closed or the call to WinHttpReceiveResponse has completed").
  **고침:** 가져오기 내내 사는 복사본, 모든 핸들을 닫은 뒤 해제.
  ④ **취소·유휴 타이머가 다른 스레드에서 요청 핸들을 닫았다.** 문서: "An application should never call WinHttpCloseHandle on a synchronous request. This can
  create a race condition"(`WinHttpCloseHandle`). 작업 스레드는 닫힌 값을 읽기·조회에 다시 넘길 수 있었다(값이 재사용되면 다른 요청의 핸들).
  **고침:** 취소·타이머는 호출자에게 바로 답하고 신호만 준다; 핸들은 작업 스레드만, 지금 하던 WinHTTP 호출이 돌아온 뒤 닫는다(그 대기는 WinHTTP
  타임아웃이 묶고, 헤더 수신 타임아웃도 요청 타임아웃으로 낮췄다 — 기본 90 s).
  ⑤ **동기 `WinHttpReadData`(64 KB 버퍼)는 버퍼가 찰 때까지 기다렸다**(리뷰의 질문; 러너에서 1 KB/500 ms 로 오는 20 KB 본문이 2 s 유휴 타이머에 걸려
  실패). **왜 못 걸렀나:** 느리게 오는 본문 테스트가 없었고, `/hang`(10 B 뒤 침묵)은 타임아웃이 정답이라 같은 증상이 정상처럼 보였다. **고침:** 문서 예제의
  고리 — `WinHttpQueryDataAvailable` 로 도착한 만큼을 물은 뒤 그만큼만 읽는다.
  ⑥ 러너에서 함께 드러난 것: WinHTTP 는 프록시와의 NTLM/Negotiate 레그를 본문 없이(Content-Length 0) 보내고 핸드셰이크가 끝나야 본문을 보낸다 — 우리가 보낸
  두 요청(처음·재시도)은 본문 그대로였다.
  소항목도 함께: TLS 1.2/1.3 만(`WINHTTP_OPTION_SECURE_PROTOCOLS`; 윈도우 10 의 WinHTTP 기본은 SSL3·1.0·1.1 허용), 압축 해제 뒤 32 MB 본문 한도, 전체
  마감(호출부 세션의 resource timeout — Cursor 사용량 120 s — 없으면 300 s), 동시 8 개 상한(슬롯은 작업 스레드가 끝날 때 반납, 대기는 취소로 끝남),
  앱 밖(`swift test`)에서는 루프백·`.invalid`/`.test` 외 호스트 거부, WinHTTP 가 못 받는 프록시 변수는 값 없이 한 번 로그.
  **스윕:** 호출부가 넣는 자격증명 헤더는 `Authorization`(Claude OAuth 사용량·프로필, Cursor 한도·사용량, Grok, OpenCode Go)과 `Cookie`(claude.ai 세션
  키, Cursor 사용량) 둘뿐(`WinHTTPFetch.credentialHeaders`). Cursor 토큰 갱신의 refresh token 은 본문에 있어 교차 출처 307/308 이면 맥처럼 다시 간다(남김).
  호출 뒤에도 호출자 버퍼를 쥐는 윈도우 API 는 DNS-SD 요청뿐이고 이미 자체 할당이다(`WinDNSSD.swift`). 다른 스레드가 쓰는 핸들을 닫는 곳은 없다(팀 소켓은
  한 스레드가 소유, `WinSocketLoop`). URLSession 으로 남는 경로(본문 스트림·WinHTTP 가 못 받는 프록시 변수·테스트 플래그)는 corelibs 대로 헤더를 다
  넘긴다 — 이 브랜치 이전과 같은 동작.
  **가드(기계):** `RedirectHeadersMacTests`(맥 동작 고정), `WindowsHTTPFetchTests` — 리디렉션 단언(같은 출처: Cookie 유지·Authorization 없음; 교차:
  Authorization 없이 따름, Cookie 면 302 반환·상대 서버 연결 0; 규칙 단위 테스트·HTTPS→HTTP; 20 홉·루프), 401 NTLM 서버(127.0.0.1·localhost 모두 요청
  1 번·Authorization 없음, 대조 = 이전 기본값), 프록시 407(재요청·로그온 제시)·직접 경로의 407(재요청 없음), 307·407 재요청 뒤 본문 동일, 압축 해제 뒤
  한도(230 B gzip → 200,000 B), 느린 본문·전체 마감, 동시 상한·대기 취소; `WindowsSeamScanTests.testWinHTTPRelaxesNoCertificateCheck`(보안 플래그 금지);
  `windows.yml` 이 거부된 실제 호스트를 나열(앱 밖 전체 스위트: 상태 호스트 둘·raw.githubusercontent.com — 기다리는 테스트 없음). **규칙:** 플랫폼 이음매의 동작 기준은 그 호출부가 원래 돌던 플랫폼(맥)이다 — 대체 구현끼리 비교하지 않는다.
  보안에 걸린 비교는 print 가 아니라 단언으로 남긴다.

- **윈도우 XCTest는 `@MainActor` 클래스에 동기 테스트 메서드가 있으면 테스트를 0개로 돌리고도 끝난다.** 그 클래스의
  테스트가 발견되지 않아 윈도우 CI가 초록이어도 아무것도 검증하지 않았다. **왜 못 걸렀나:** 맥에서는 그대로 발견돼 통과하고,
  윈도우 워크플로는 종료 코드만 봤다. **가드(기계):** `SharedSourcesScanTests` 가 윈도우에서 도는 파일의 `@MainActor`
  클래스(확장 포함) 안 동기 `func test…()` 를 실패시키고, 윈도우 워크플로가 실행된 테스트 수 하한을 확인한다.
  **규칙:** 윈도우에서 도는 `@MainActor` 테스트는 `async` 로 쓴다.

- **기록된 순서의 `.last` 를 단언하는 테스트는 늦게 합쳐져 도착하는 비동기 조회의 순서에 기댄다.** 마지막 값이 "기대한 최종
  상태"인지는 어느 조회가 늦게 끝나느냐에 달려 있어, 실행 환경의 타이밍에 따라 결과가 달라질 수 있다(윈도우 CI 이식 중 발견). **규칙:** 어떤 시점까지의
  시퀀스 전체를 단언하거나, 알려진 지점까지 기다린 뒤 단언한다. `.last` 로 최종 상태를 보려면 그 값이 정말 마지막에 쓰이는 것이
  보장돼야 한다.

- **SwiftPM은 `mac-only.txt` 가 바뀐 뒤에도 옛 소스 목록을 쓸 수 있다.** 매니페스트가 파일 시스템 목록을 읽어 만든 결과가
  캐시되어 있으면 목록을 고쳐도 같은 파일 집합을 빌드한다(공용 집합 빌드가 "통과"해도 새 목록을 본 것이 아니다).
  `scripts/shared-check.sh` 가 `debug.yaml` 을 지우고 매니페스트 캐시를 끄는 것으로 막는다. **규칙:** 빌드 입력을 파일
  목록으로 정하는 구성은, 목록을 바꾼 뒤 캐시를 지우고 재현되는지 한 번 확인한다.

- **`await store.refresh()` 가 돌아왔다고 그 결과가 이미 기록됐다고 가정하지 않는다 (테스트에서의 강제 언래핑 금지).**
  `LocalizationErrorsTests` 가 `refresh` 직후 `store.lastErrorDescription!` 를 풀었는데, 윈도우 CI 에서 한 번 nil 이어서
  프로세스가 죽었고 뒤의 테스트 1,500여 개가 돌지 않았다(직전 실행들은 통과). 위의 "기록된 순서의 `.last`" 항목과 같은 부류다:
  합쳐진 조회가 늦게 끝나면 기다린 호출이 먼저 돌아온다. 정확한 경로는 재현하지 못했다. **고침:** 값이 기록될 때까지 기다린 뒤
  단언하고, 끝내 없으면 `XCTFail` 한다. **규칙:** 테스트에서 비동기 결과를 `!` 로 풀지 않는다 — 크래시는 실패 하나가 아니라
  실행 전체를 잃는다.
- **경로 목록 구분자(`:`)와 경로 구분자(`/`)를 문자열로 박아 두면 윈도우에서 조용히 틀린다.** `BinaryLocator` 가 PATH 를
  `":"` 로 나누고 이어서, 윈도우(`;`, 드라이브 문자에 `:` 포함)에서는 항목이 잘못 쪼개졌다. **왜 못 걸렀나:** 맥에서는 옳은 값이라
  모든 테스트가 통과했고, 그 테스트 파일은 윈도우 실행에서 빠져 있었다(기대값도 `:` 를 박아 두었다). **고침:**
  `PlatformCompat.pathListSeparator` 를 쓰고 테스트가 플랫폼 구분자로 단언한다(`WindowsPathTests`, `BinaryLocatorTests` 가 두 OS 에서 돈다).
  **부류 스윕(2026-11-13):** 공용 소스(`Core`, `Team`)에서 `separator: ":"`, `separatedBy: ":"`, PATH 기본값 리터럴을 grep 했고
  남은 것은 `BinaryLocator` 의 POSIX 기본 PATH 한 곳뿐이다(윈도우용 도구 디렉터리는 4단계 범위). 홈 경로를 문자열로 비교하는 곳은
  윈도우에서 `\` 와 `/` 표기가 섞여 중복 제거가 듣지 않는다 — 경로 비교는 `URL.path` 끼리 한다. **규칙:** 공용 코드에서 경로를
  나누거나 잇는 문자는 `PlatformCompat` 에서 가져오고, 그 코드를 지키는 테스트는 윈도우에서도 돌게 둔다.
- **윈도우 체크아웃은 텍스트 파일을 CRLF 로 바꾸므로 목록을 읽는 스크립트는 `\r` 을 떼야 한다.** 줄 끝의 `\r` 이 경로의
  일부가 되어 항목이 어떤 파일과도 맞지 않는다. 스캔 테스트의 목록 파서는 이미 `isNewline`/trim 으로 견디고, 스크립트는 `\r` 을
  제거한다. **규칙:** 목록·스크립트 입력 파일을 읽는 코드는 CRLF 를 입력으로 가정하고, `.gitattributes` 로 고정이 필요한 파일은
  고정한다. (JSONL 사용량 로그는 줄 끝 `\r` 이 있어도 JSON 공백으로 파싱되어 같은 결과다: `WindowsPathTests`.)

## 자격증명·Keychain

- **앱 소유 keychain 항목 금지.** 앱이 만든 keychain 항목은 코드서명(cdhash)이 바뀔 때마다(로컬 재빌드·
  실사용자 매 업그레이드) 항목 ACL 이 안 맞아 접근 허용 프롬프트를 유발한다 — **no-UI 쿼리로도 이 ACL
  프롬프트는 억제 안 됨**(#58). 토큰류는 인메모리 캐시 + 파일(`~/.claude/.credentials.json`) 재취득으로
  처리하고, 앱 전용 keychain 캐시 항목을 새로 만들지 말 것.
- **자동 폴링은 앱 자신의 Keychain API 로 Claude 키체인을 절대 읽지 마라(`SecItemCopyMatching` 은 사용자 동작 전용).** no-UI 쿼리
  (`kSecUseAuthenticationUIFail`/`LAContext`)는 '인증' 프롬프트만 억제할 뿐 **잠긴·미승인 login 키체인의
  '암호 입력' 다이얼로그는 못 막는다** — 실측: 캐시 만료 폴 도중 `SecItemCopyMatching` 이 13초간 블록하며
  팝업(토큰 만료 시점마다 하루 몇 회, 아침 등). self-signed 앱은 '항상 허용' 승인도 불안정. → 타이머 경로
  `fetch(allowKeychainPrompt: false)` 는 파일 → 캐시 → `/usr/bin/security`(아래) 순으로 읽고 앱 자신의 `SecItemCopyMatching` 은 부르지 않는다
  (`OAuthAccessTokenCache.accessToken` 의 `guard allowKeychainPrompt` 가 앱 API 읽기 앞에 위치). 앱 API 로 키체인을 읽는 건 명시적 사용자 버튼
  (설정 갱신·팝오버 `claudeLimitsRefreshRow`, `refreshLimitTokenFromKeychain`)에서만. 파일이 유효
  토큰을 들고 있으면 매 자동 폴이 그걸 다시 읽는다. 회귀 가드: `testAutomaticPathNeverQueriesTheKeychain`(앱 API 0회)·
  `testAutoRefreshUsesNoPromptPathManualUsesPromptPath`.
  **자동 경로의 유일한 읽기(맥, 2026-11):** `/usr/bin/security find-generic-password -s <service> -a <NSUserName()> -w`
  (없으면 `-a` 없이 한 번 더)를 `OAuthAccessTokenCache.readClaudeKeychainViaSecurityTool` 이 실행한다. Claude Code 가 항목을 이 도구로
  만들고 읽어 항목의 복호화 ACL 이 `/usr/bin/security` 를 신뢰하므로 다이얼로그가 없다(앱은 self-signed 라 신뢰 못 받음).
  가드(순서, 하나라도 걸리면 프로세스 없이 nil): 접근 끔 → 시험 이음매 없고 번들 앱 아님(`swift test` 가 개발자 키체인을 안 읽게) →
  꺼짐(시간 초과 3 s 또는 종료 코드 0·44 밖 — 사용자가 다이얼로그를 거절한 것일 수 있다 — 이면 앱 재시작·사용자 갱신 버튼까지) → 기본 키체인 잠김(`SecKeychainGetStatus`; 잠기면 `security` 가 잠금 해제 다이얼로그를 띄운다; 확인한 키체인 경로를 `security` 인자로 넘겨 같은 파일만 검색).
  stdout·토큰·계정 이름은 로그에 남기지 않는다. **자격증명 탐지 5-whys:** 증상 — 회사 사용량 시트에 맥 사용자 다수가 "플랜 정보 없음".
  직접원인 — 키체인에만 로그인이 있는 맥은 자동 폴이 키체인을 안 읽어(위 규칙) 갱신 버튼을 누르기 전·앱 재시작 후·토큰 만료(약 8 h) 뒤엔 한도가 없어
  한도 행이 전송되지 않았다. 왜 못 걸렀나 — 리포터 테스트는 한도를 주입하고, 개발자 맥에는 `~/.claude/.credentials.json` 이 있어 닷푸딩에선 늘 한도가
  있었으며, 키체인만 있는 맥을 아무도 확인하지 않았다. 가드 — `KeychainToolReadTests`(도구 경유 읽기·`-a` 폴백·접근 끔·잠김·시간 초과 후 꺼짐·만료·여러
  서비스·번들 아님·예상 밖 종료 코드, 가드마다 제거 시 실패 확인, 실제 `/usr/bin/security` 로 없는 서비스 → 종료 44, 실제 러너 시간 초과·stdout 캡처).
  `Credential` 은 `description`/`debugDescription` 에서 토큰을 가린다(시험 실패 메시지가 토큰을 찍던 일 방지); 시험은 UUID 서비스 이름만 쓴다.
  (완전 근절은 Developer ID
  notarization 으로 '항상 허용' 승인을 안정화하는 것뿐 — 신뢰된 서명 신원이라야 ACL 승인이 지속된다.
  미도입.)
- **Claude Keychain '항상 허용'은 ACL 리셋으로 유지되지 않는다 — 비간섭 상시 `(?)` 도움말로 세션 키 등록을 유도.**
  macOS 의 `security add-generic-password -U` 동작상 Claude CLI 가 토큰을 갱신할 때마다 기존 항목의 ACL(항상 허용)이
  날아간다. 사용자가 시스템 창에서 '항상 허용'을 눌렀음에도 다음 번에 또 암호를 묻는 것은 앱 버그가 아닌 macOS+CLI 한계이므로,
  시끄러운 팝업 배너 대신 `한도 (공식)` 헤더 옆의 은은한 `(?)` 팝오버 및 설정 세션 키 입력란으로의 원클릭 바운스(#275)를 통해
  키체인 사용자에게는 0% 노이즈를 유지하면서도 세션 키 우회로를 친절히 안내한다.
- **Claude 의 `refreshToken` 은 보이지만 우리가 쓰면 안 된다 — 갱신 시 회전되어 Claude Code 를 깨뜨린다.**
  키체인 항목(`claudeAiOauth`)에는 `accessToken`(수명 ~5h) 옆에 `refreshToken`·`refreshTokenExpiresAt`
  (~15일)이 함께 들어 있다. "그걸로 갱신하면 키체인 접근이 5시간마다 → 15일마다로 줄겠다"는 발상이
  자연스럽게 나오는데, **하면 안 된다.** Claude Code 바이너리 확인: 갱신은
  `POST {baseURL}/v1/oauth/token`(`grant_type=refresh_token`, `client_id`)이고 응답 처리 함수가
  `ltu(e,t) → { refreshToken: t.refreshToken, … }` 로 **저장된 refreshToken 을 응답의 새 값으로 교체**한다.
  즉 회전한다. 외부 앱이 대신 갱신하면 Claude Code 의 키체인 사본이 죽은 토큰이 되어 **재로그인**을 요구한다.
  피하려면 남의 자격증명 저장소에 write 해야 하는데 그건 위 '앱 소유 keychain 항목 금지' 가 막는 영역이다.
  **Antigravity 와 다른 이유가 여기 있다** — Google 은 회전하지 않아서 `AntigravityTokenCache` 가
  `refreshToken: refreshToken` 으로 기존 값을 그대로 재사용한다(`refreshGoogleToken`). 두 프로바이더의
  토큰 규약이 다른 것이지 Claude 쪽 구현 누락이 아니다.
  반대로 Antigravity 는 이 갱신을 **자동 경로에서도** 써야 한다 — 토큰 파일 없이 수동 갱신으로 키체인에서
  받은 자격증명은 메모리에 refresh token 을 들고 있는데, 자동 폴이 만료만 보고 `keychainInteractionNotAllowed`
  를 던져 한도가 ~1시간 뒤부터 수동 클릭 전까지 stale 이었다(#415). 회귀:
  `testAutoPollRefreshesAnExpiredKeychainCredentialWithoutKeychain`.
  **확실도:** 회전은 "Claude Code 가 응답의 토큰으로 교체 저장한다"에서 추론한 것이고 실제로 갱신을
  걸어 확인하지는 않았다 — 틀렸을 때의 대가가 사용자의 주 도구 로그인 파손이라 시험 자체를 하지 않았다.
  판단 근거는 확률이 아니라 비대칭이다: **잘 돼야 #241 세션 키가 이미 더 완전하게 주는 것(간격 축소 vs
  프롬프트 제거)의 열화판이고, 잘못되면 Claude Code 가 깨진다.**
  같은 맥락에서 기각된 것: **사용자 경로에 무프롬프트 선시도를 덧대는 것**(Antigravity 방식). ACL 이
  승인돼 있으면 프롬프트 쿼리도 조용히 통과하고, 미승인이면 무프롬프트는 실패해 결국 프롬프트를 띄운다 —
  두 경로의 결과가 같아 얻는 게 없다. 패턴이 다른 프로바이더에 있다는 것만으로 이식하지 마라.
- **인메모리 토큰 캐시는 만료만 보면 안 된다 — 원본 파일이 다른 유효 토큰으로 바뀌었는지도 본다.**
  `/login` 으로 계정을 갈아타면 `~/.claude/.credentials.json` 이 새 토큰으로 덮이지만, 캐시가 옛
  토큰의 `expiresAt` 까지 그걸 무시하면 공식 5h/주 바가 이전 계정에 붙고 컴패니언 EXP 만 로컬
  jsonl 로 계속 오른다(#227). 자동 폴은 캐시가 유효하면 키체인(도구)을 읽지 않으므로 **파일 peek 를 캐시 히트보다 앞에**
  둔다. 파일이 없거나 `"claudeAiOauth": null` 이면 캐시를 유지(로그아웃·`CLAUDE_CONFIG_DIR` 잔여
  파일 — 기존 `credentialsFileIsAccountOAuthMissing` 과 같은 이유). 같은 부류: Antigravity
  `jetski-standalone-oauth-token` 은 파일 로드 시 `expiresAt=nil` 이라 캐시가 만료로 풀리지 않는다.
  회귀: `testClaudeAutoPollPicksUpInPlaceAccountSwitch`·`testAntigravityAutoPollPicksUpTokenFileSwitch`.
  캐시-우선 early return 을 되돌리면 이 두 테스트가 실패해야 한다.
- **파일이 없는 Keychain-only 설치는 사용자 갱신도 만료만 보면 이전 계정에 붙는다.** #227 은
  파일이 새 유효 토큰으로 덮이는 경우를 고쳤다. 파일이 없으면 같은 메모리 캐시가 남고, 같은 Team 의
  다른 메일은 401 을 안 주므로 invalidate 경로에 안 들어간다. Refresh 를 눌러도 Keychain 을 안 읽고
  로그는 "keychain"이라고 남긴다(#300). 사용자 동작(`allowKeychainPrompt: true`)만
  `bypassCache: true`. 자동 폴은 그대로 캐시 — 키체인 다이얼로그를 되살리면 #210 이 돌아온다.
  같은 한 줄: `AntigravityRateLimitsProvider.fetch`. 회귀:
  `testManualRefreshRereadsKeychainWhenCachedTokenIsStillValid`. `bypassCache` 를 빼면
  Authorization 이 `token-account-a` 로 남고 Keychain 조회가 0 이다.
- **`kSecMatchLimitAll` 과 `kSecReturnData` 는 같이 못 쓴다 — macOS 가 errSecParam(-50) 으로 거절한다.**
  "서비스에 항목이 여럿일 수 있으니 전부 받아서 유효한 걸 고르자"는 발상 자체는 옳지만(#229), 한 번의
  `SecItemCopyMatching` 으로 *모든 항목의 데이터*를 받는 쿼리는 **파라미터 단계에서** 거절된다. 항목이
  없어서가 아니라 조합이 무효라서라, ACL 승인·항목 존재·재로그인 어느 것으로도 우회되지 않는다.
  결과는 조용한 전면 실패였다 — Keychain 에만 자격증명이 있는 사용자(파일 `~/.claude/.credentials.json`
  없음)는 수동 갱신을 눌러도 `keychainUnavailable(-50)` 만 나고 공식 한도가 **영구히** 안 떴다.
  → 두 단계로 나눈다: ① `kSecMatchLimitAll` + `kSecReturnAttributes` 로 `acct` 목록만 열거
  ② 계정마다 `kSecMatchLimitOne` + `kSecReturnData` 로 단건 조회. 계정 속성을 못 얻으면 스코프 없는
  단건 읽기로 폴백한다(항목이 하나뿐인 흔한 경우).
  **5-whys(왜 못 걸렀나):** 테스트가 `extractDataItems(from:)` 라는 순수 파서만 합성 배열로 검증했다.
  결함은 그 함수가 아니라 **그 함수에 값을 넘겨주는 쿼리**에 있었고, `SecItemCopyMatching` 은 테스트
  경로에 아예 없었다 — 결함 트리거와 다른 경로로 통과하는 전형이다. 딕셔너리 모양만 단정하는 테스트도
  같은 이유로 부족하다: 어떤 키 조합이 무효인지는 **Security 프레임워크만 안다.**
  가드: `testKeychainQueriesAreAcceptedBySecurityFramework` — 존재하지 않는 서비스명(매칭 0건이라
  ACL·프롬프트에 안 닿음)으로 프로덕션 쿼리를 실제 API 에 던져 `errSecParam` 이 아님을 단정한다.
  기대값이 "성공"이 아니라 **"파라미터가 유효하다"(`errSecItemNotFound`)** 인 게 요점이다.
  `kSecMatchLimitAll` 을 데이터 쿼리에 되돌리면 이 테스트가 빨개진다(주입 확인 완료).
- **자격증명 "없음"과 "계정 로그인 없음"은 다른 안내다.** Claude Code 2.1.x 의 `Claude Code-credentials`
  항목이 MCP 서버 OAuth(`mcpOAuth`) 상태만 담고 계정 토큰(`claudeAiOauth`)은 안 담는 경우가 있다. 이때
  파싱 실패를 형식 오류로 뭉뚱그리면 "재로그인하면 된다"를 안내 못 해 한도 섹션이 원인 불명으로 사라진다.
  → `LimitsError.credentialMissingAccountOAuth` 로 구분해 재로그인 안내를 띄운다
  (`OAuthCredentialData.isAccountOAuthMissing`).
- **다중 Keychain 항목 순회 시 사용자 계정을 최우선으로 정렬하라 — 안 그러면 항목마다 시스템 암호 프롬프트가 연쇄된다.**
  #243 에서 `errSecParam(-50)` 회피를 위해 속성 열거 후 단건 데이터 조회 루프로 바꿨는데,
  Claude Code 가 MCP OAuth 를 쓰면 `acct="unknown"` 항목이 생겨 서비스 내 항목이 2개 이상이 된다.
  macOS 의 ACL 승인은 항목(Item) 단위라 `unknown` 에 암호를 입력해도 `justinjeong` 에서 또 암호를 묻는다.
  속성 목록에서 `NSUserName()` 을 1순위, 이메일(`@`)을 2순위, 일반 계정을 3순위, `unknown` 을 최하위로 정렬해
  진짜 계정을 먼저 찌르면, 첫 조회에서 바로 유효 토큰(`claudeAiOauth`)을 찾아 루프를 끝내므로 2회차 암호 창이 원천 소멸한다.
  가드: `testPrioritizedAccountNamesPlacesCurrentUserNameFirstAndUnknownLast`·`testPrioritizedAccountNamesFullHierarchy`.

- **메뉴바 전용 앱도 편집 메뉴가 있어야 입력란에서 Cmd+C/V가 된다.** macOS는 Cmd+V를 메인 메뉴의 단축키로 처리한다.
  SwiftUI `_EmptyScene` 은 "View" 하나뿐인 메인 메뉴를 만들어서, 팀 코드·세션 키·검색 등 앱의 모든 입력란에서 키보드
  붙여넣기와 복사가 안 됐다(원작부터 있던 문제). **왜 못 걸렀나:** 입력 테스트가 `stringValue`를 직접 넣거나 편집기에
  `insertText`를 불러서 메뉴 경로를 밟지 않았다. `StandardEditMenu`가 기동 때 편집 메뉴를 붙인다. XCTest는 앱 이벤트
  루프를 돌리지 않아 실제 Cmd+V를 보낼 수 없으므로, 같은 SwiftUI 구성의 작은 앱에서 `postEvent`로 보낸 Cmd+V가 수정
  전에는 아무것도 넣지 못하고 수정 후에는 붙여넣는 것을 확인했다. 가드: `StandardEditMenuTests`.
- **편집 메뉴를 직접 만들면 AppKit이 표준 메뉴에 붙여 주던 항목도 직접 넣어야 한다.** 위 수정 뒤에도 "Emoji & Symbols"
  (⌃⌘Space)는 붙지 않아, 광장 한마디를 포함한 앱의 모든 입력란에서 이모지를 넣을 방법이 없었다. 실행 중인 앱의 메뉴를
  손쉬운 사용 API로 읽어 항목이 없음을 확인했다. **왜 못 걸렀나:** `StandardEditMenuTests`는 그때 고장 난 여섯 항목만
  고정했고, 한마디 테스트는 이모지를 `TeamChat.prepared`와 말풍선 그리기로만 다뤄 입력 경로를 밟지 않았다(보내기·그리기는
  됐고 넣기만 안 됐다). 부류 스윕: 표준 편집 메뉴에서 한 줄 입력란이 단축키로 쓰는 항목(실행 취소·다시 실행·자르기·복사·
  붙이기·전체 선택·이모지)을 다시 맞춰 봤고, 서식 붙이기·찾기·맞춤법은 서식 없는 한 줄 입력란에 쓸 일이 없어 넣지 않았다.
  가드: `StandardEditMenuTests`(⌃⌘Space 항목). **이 메뉴 항목만으로는 모자랐다(아래 항목).**
- **시스템 UI에 넘기는 기능은 화면에서 뜨는 것을 보기 전에는 그것만으로 내보내지 않는다.** v2.5.606의 광장 😀 단추는
  `NSApp.orderFrontCharacterPalette`만 불렀는데, 적어도 한 Mac(macOS 26.5)에서는 광장 입력창에서 macOS 이모지 창이
  아예 뜨지 않았다. ⌃⌘Space와 🌐 키로도 안 떴고, 다른 팀원의 Mac에서는 떴다. **왜 못 걸렀나:** 단위 테스트는 여는 함수를
  바꿔 끼워 "불렀다"만 확인했고(뜨는지는 앱 밖의 일이라 확인할 수 없다), 실제 화면 확인은 앱을 맨 앞에 둘 수 없어서
  건너뛰었다. PR에는 "확인 못 함"으로 적었지만 그대로 내보냈다. 같은 구성의 작은 시험 앱에서도 호출은 됐지만 창이 뜨지 않았다.
  수정: 😀가 앱 안의 이모지 판(40개)을 펼치고, 누르면 커서 자리에 넣는다. 결과가 앱 안에 있어 끝까지 테스트할 수 있다.
  부류 스윕: 앱에서 시스템 패널을 여는 다른 호출(색상·글꼴 패널, 문자 팔레트)을 찾았고 이것 하나뿐이었다. 가드:
  `PlazaChatInputTests`의 이모지 판 테스트(펼치기·커서 자리 넣기·길이 제한·다시 열 때 접힘·판이 막대 안에 들어감).

- **"이 값이 될 때까지 기다린다"는 조건이 처음부터 참일 수 있으면 기다림이 아니다.** `testMenuCarriesTheTeammatesPickedColor`는
  팀원 이름이 고른 색(0x8FF0C8)이 될 때까지 기다렸는데, 멤버 ID가 무작위라 12번에 1번은 그 색이 원래 색이었다. 그때는 고른
  색이 오기 전에 기다림이 끝나 v2.5.607 릴리스 게이트에서 실패했다. **왜 못 걸렀나:** 로컬과 CI에서 몇 번 돌린 동안 우연히
  안 겹쳤다. 수정: 원래 색과 다른 색을 고른다. 부류 스윕: 이름 색을 기다리거나 비교하는 다른 테스트
  (`testTeammatesPickedNameColorShowsHere`, `testPickingMyNameColorPaintsMeAndIsKept`)는 이미 원래 색을 피하고, 세션·설정 쪽은 색 값을
  직접 비교해 우연히 참일 수 없다.

- **도트 글꼴은 글꼴 격자의 정수배 크기로만 쓴다.** 광장 글자는 Galmuri11(12픽셀 격자)을 14·15·16pt로 그려, 레티나에서
  글꼴 한 도트가 2.33~2.67 기기 픽셀이 되어 획 굵기가 2와 3픽셀로 들쭉날쭉했다(팀원 보고: "폰트가 조금 깨진다"). 앤티앨리어싱을
  끄고 그리는 말풍선에서 가장 심했다. **왜 못 걸렀나:** 글자 테스트는 넘침과 줄 수만 봤고, 크기는 화면마다 눈대중으로 골랐다.
  수정: `PlazaTextSize` 두 가지만 쓴다. 본문은 Galmuri14(15픽셀 격자)를 15pt로, 작은 글자는 Galmuri11을 12pt로 그려 1배·2배 화면 모두
  한 도트가 정수 픽셀이다. 부류 스윕: 광장의 모든 `PlazaResources.font` 호출(30곳)과 그림으로 그리는 글자(말풍선, 이모트의 ㅋㅋ)를
  옮겼고, 한 도트 옆으로 미는 굵게 효과(0.6pt → 1pt)도 격자에 맞췄다. 이름표는 시스템 글꼴이라 해당 없다. 가드:
  `testEachSizeIsOnItsFontsPixelGrid`(번들 글꼴 파일에서 격자를 읽어 크기와 맞는지 확인).

- **고치는 원소의 인자에서 같은 컬렉션을 읽지 않는다.** `remotes[id]?.advance(by:blocked: occupiedTiles(...))`는
  `remotes`의 원소를 고치는 동안 인자에서 `remotes`를 다시 읽어 Swift 배타 접근 검사에 걸려 멈췄다(릴리스 빌드도 검사한다).
  충돌 테스트가 처음 돌 때 잡혔다. 수정: 읽는 값을 먼저 구해 지역 변수로 넘긴다. 부류 스윕: 광장 장면에서 원소를 고치는 다른
  호출(`remotes[id]?.…(`)은 이것 하나였다. 가드: `PlazaCollisionTests`(장면을 실제로 돌린다).

- **밖에서 오는 일로 내 상태가 바뀌면, 장면이 멈춰 있어도 바로 반영한다.** 몸통박치기에 맞으면 내 걸음에 '밀림'만
  걸어 두고 다음 화면(`update`)이 한 칸을 옮겼는데, 광장 창이 다른 창에 가려지면 그리기와 함께 장면이 멈춰(`isPaused`)
  창을 다시 볼 때까지 밀리지 않았다. 민 쪽에서는 아무 일도 안 일어난 것처럼 보였다(팀원 보고). **왜 못 걸렀나:** 테스트는
  장면을 직접 `update`로 돌려 늘 보이는 창처럼만 다뤘다. 수정: 멈춘 장면이면 그 자리에서 한 칸을 마치고 위치를 바로
  보낸다. 부류 스윕: 팀원이 보낸 것으로 내 위치나 상태가 바뀌는 길은 밀림 하나였고, 말풍선·점프·충격 그림은 보이는 것뿐이라
  창을 볼 때 그려지면 된다. 가드: `testTackleWhileMyPlazaIsHiddenStillPushesMe`.

- **규칙의 예외는 그 목적만큼만 연다.** 연못(#68)은 헤엄치다 알이 된 나를 물에서 꺼내려고, 물속이면 알도 방향키로
  걷게 했다(`canWalk || isMeInWater`). 이 예외는 '물가로 나가기'가 아니라 '물속에서 마음대로 걷기'를 열어서, 알이 연못
  안을 계속 헤엄쳐 다닐 수 있었다(사용자 보고). **왜 못 걸렀나:** 테스트는 땅 쪽 방향키만 눌러 '나온다'만 확인했고,
  예외 갈래(`isMeInWater`만 참)에서 목적 밖의 입력(물 쪽 방향키)은 한 번도 넣지 않았다. 수정: 알은 물속에서도 방향키를
  받지 않고, 장면이 가장 가까운 빈 물가로 한 칸씩 저절로 올려 보낸다(`PlazaPond.stepAshore`). 부류 스윕: 알이 `canWalk`를
  거치지 않고 움직이는 다른 길은 몸통박치기에 밀리기(의도된 동작이고 땅에서 물로는 밀리지 않는다), 모닥불 자리에 앉기
  (물 칸이 아니다)뿐이다. 따라가기와 목록에서 걸어가기는 `canWalk`로 막혀 있다. 가드:
  `testAnEggInTheWaterCannotSwimAround`, `testAnEggInTheWaterClimbsOutByItselfThenStaysOnLand`,
  `testAnEggClimbsOutBesideATeammateOnTheNearestShore`, `testStepAshoreTakesTheShortestWaterRouteToFreeLand`.

- **한 프레임에 칸이 둘 바뀌면 그 사이 칸을 팀원에게 못 보낸다 — 프레임 간격 상한은 가장 짧은 칸보다 짧게.** 달리기(칸당
  0.075초)를 넣었는데 장면의 `maxFrameDelta`는 걷기(0.15초) 시절의 0.1초 그대로라, 멈칫한 프레임 한 번에 칸을 둘 끝내고
  위치 보고는 한 번만 나갔다. 팀원 쪽 `PlazaRemoteMotion.moveTo`는 한 칸 차이만 이어 걷고 그 밖은 순간 이동한다(PR 리뷰가
  찾음). **왜 못 걸렀나:** 달리기 테스트는 1/60·1/30초 간격으로만 장면을 돌려 칸보다 긴 프레임을 밟지 않았고, 걷기 때는
  상한이 칸보다 짧아 이 경로가 아예 없었다. 수정: 상한을 0.07초로 낮추고 `상한 < runStepDuration`을 테스트로 묶었다.
  부류 스윕: 칸 단위로 움직이는 다른 것 중 위치를 보내는 것은 내 걸음뿐이다(팀원 움직임·쉼터 어슬렁·날씨 입자는 이 화면 안에서만
  그린다). 가드: `testASlowFrameWhileRunningReportsEveryTile`(0.1초 프레임으로 달려 보고된 칸이 모두 한 칸씩 이어지는지 본다).

## 동시성

- **비동기 완료가 "그 사이 교체된 대상"에 착지하지 않게 하라 — 상태를 통째로 바꾸는 경로를 새로 만들면
  진행 중인 await 를 전수 점검한다.** 이 레포가 세 번 겪은 부류다(#136·#138 스프라이트, 그리고 세이브
  불러오기 중 부화). `isHatching` 같은 중복 실행 락은 *같은 작업의 재진입*만 막을 뿐, await 창에서 상태가
  **다른 주체로 교체되는 것**은 못 막는다. 방어는 두 형태 중 하나로 통일한다: ① `activeGeneration` 을
  진입 시 캡처하고 mutation 직전 재검사(`hatchCore`·`revealDitto`·`loadCurrentLine`) ② 대상을 id 로 다시
  찾아 없으면 무시(`dexChainNames` 의 `firstIndex(where: id)`). 회귀 가드는 sleep 이 아니라 신호(actor +
  continuation)로 await 지점을 정확히 잡아 재현한다 — `testImportDuringHatchDiscardsTheHatch`.
  **세대는 호출 체인에서 *가장 이른* await 앞에서 캡처하라 — 안쪽 함수에서 캡처하면 가드가 자동 통과한다.**
  딥리뷰 실측: `hatchCore` 에만 가드를 넣었더니 `hatchIfNeeded` 의 `chooseBase()` 창에 들어온 교체를 못
  막았다. `hatchCore` 는 *교체 이후*의 세대를 캡처하므로 `activeGeneration == generation` 이 항상 참이 된다
  (출발할 때 봐야 할 시계를 도착해서 보는 격). 가드를 넣을 땐 그 함수 위의 await 까지 거슬러 확인하고,
  회귀 테스트도 **그 await 를 실제로 지나는 진입점**으로 써라 — `hatch(baseID:)` 경로 테스트는
  `chooseBase()` 를 안 지나 통과하면서 아무것도 지키지 않았다(`testImportDuringSpeciesRollDiscardsTheHatch`).

- **Broadcast the position before a flag that depends on it.** Climbing out of a dive cleared `isDiving` and sent it
  with the old water tile; the land tile went out as a separate presence afterwards. A receiver handling the first frame
  alone read "in the water, no longer diving" and played a surfacing splash that never happened (`advancePond` ran before
  `reportLocalPosition`). **Why nothing caught it:** the dive tests checked the sender's end state and the receiver's final
  flag, never the order of the frames on the wire. **Capture:** `advancePond` reports the position before
  `onDivingChange(false)`, and `testClimbingOutOfADiveSendsTheLandTileFirst` reads the sent presences in order (it fails
  with the order restored). `startFocus` already orders its position and flag this way on purpose.
  **Class sweep:** the other flag writers (`setDiving` from Z, the dive limit, closing, hiding) leave the tile where it is, so
  no tile and flag can disagree there.

- **재시도·대기 Task 는 `self` 를 붙들고 기다리지 않는다 — 약한 참조로 기다리고 깬 뒤에 되살린다.** 광장 컨트롤러의
  스프라이트 재시도(`startMemberLoad`/`loadCharacter`)가 `Task { await retry… }` 로 `self` 를 강하게 잡은 채 30초를
  자고 깨어 또 재시도했다. 그림이 영영 안 오면 컨트롤러가 주인(테스트 케이스)이 사라진 뒤에도 안 죽고, Ditto 루프(0.05초)가
  이미 해제된 `[unowned self]` 시계를 불러 `swift test` 전체가 signal 6 으로 죽었다(`PlazaFireworksTests` 에서 터졌지만
  원인은 앞선 스위트). **5-whys:** 증상 크래시 → 해제된 테스트 케이스의 시계 호출 → 닫히지 않은 컨트롤러가 틱 중 → 재시도
  체인이 `self` 를 강하게 붙듦(빈 fetcher 는 항상 placeholder) → 왜 못 걸렀나: 작업마다 집중 필터만 돌렸고 전체 스위트는
  마지막에 한 번이라 다른 스위트의 좀비 컨트롤러를 볼 일이 없었다. 기존 1초 틱은 같은 좀비를 두고도 시계를 부르지 않아 숨었다.
  수정: 기다림은 `[weak self]` Task 가 맡고 `self` 는 깬 뒤에 다시 얻는다(`self` 를 건 await 는 로딩 호출뿐). 가드:
  `PlazaControllerLifetimeTests`(재시도 중인 컨트롤러가 놓으면 죽는다; 옛 코드로 되돌리면 실패). 부류 스윕: 컨트롤러의 다른
  `Task` 는 이미 `[weak self]`(`focusTick`·`dittoLoop`·배너·단체 사진·`applyDiveLimit`)거나 단발 await(`viewCard`)다. 이 수정으로
  컨트롤러가 정말 죽게 되자 놓은 컨트롤러에 기대던 두 테스트(`PlazaCardTests` 의 `let (_, …) = await standing()`)가 드러나
  컨트롤러를 붙들게 고쳤다 — 장면 콜백은 컨트롤러를 약하게 쥐므로 테스트가 컨트롤러를 쥐고 있어야 한다.

- **테스트는 "대상이 나타났다"가 아니라 그 테스트가 쓰는 조건을 기다린다 — 교차 세션 전달은 값이 맞을 때까지(기한을 두고) 폴링한다.**
  `testATeammatesDanceStartTimeReachesThePlaza` 가 약 3번에 1번 실패했다(병합 기점에서도 같다). 처음엔 `settle` 이 200번
  `yield` 하고 포기해서라고 보았으나, 기다림을 10초 기한 폴링으로 바꿔도 같은 비율로 실패했다. **5-whys:** 증상 내가 팀원의 춤을
  못 따라 춤 → 팀원이 내 `togetherRange`(2칸) 밖에 그려져 있었다 → 팀원의 위치 소식이 오기 전에는 장면이 그 팀원을 무작위
  쉼터 칸에 그리는데, 테스트가 `memberTiles[id] != nil`(쉼터 칸에서도 즉시 참)만 기다리고 바로 춤 소식을 보냈다 → 왜 못
  걸렀나: 기다림이 "나타남"을 확인했고 결과 단언은 "따라 춤"을 확인해서 위치가 둘을 잇는다는 걸 아무도 안 봤다; 쉼터 칸이 우연히
  가까운 날은 통과해 거짓 안심을 줬다. **수정:** 보낼 칸(`spot`)이 될 때까지 기다린다. 대기 도우미(`TeamRuntimeTests.settle`
  두 곳)는 `yield` 횟수 대신 10초 기한 폴링으로 바꿨다. **같은 부류 스윕:** `memberTiles[...] != nil` 만 기다린 뒤 거리·위치에
  기대는 테스트는 이 하나뿐이었다(나머지는 위치 무관이거나 곧바로 정확한 칸을 기다린다: `testMimicKindsReachThePlaza` 등).
  `mimicPlaza` 도 같은 틈(쉼터 칸이 우연히 기다리던 칸과 같아, 장면 칸은 맞는데 컨트롤러의 멤버 사본이 아직 '광장 밖')을 가졌고, 처음엔 `yield` 50번으로 덮었다가 이제 칸과 `scene.memberIsAway == false` 를 조건으로 기다린다. **가드:** 옛 조건(`!= nil`)으로
  되돌리면 `TeamRuntimeTests` 12번 중 2번 실패가 되살아난다(고치면 12/12 통과).

## 프로세스·인스턴스

- **LaunchAgent의 등록 성공과 실행 성공은 별개다.** macOS 26.5에서 PokeTokenBar 2.5.7 자체 서명
  배포본은 `SMAppService.agent.status == .enabled`였지만, launchd가 직접 실행하면 AMFI가
  `Launch Constraint Violation`으로 프로세스를 종료했다. 수동 실행과 기존 E2E의 `open`은
  LaunchServices 경로여서 이 실패를 검증하지 못했다. 설정은 `SMAppService.mainApp`으로 등록하고
  승인이 필요할 때 로그인 항목 설정을 연다. 기존 에이전트는 새 항목이 활성화된 뒤 제거한다.
  기존 에이전트가 현재 앱을 실행했다면 앱이 갑자기 종료되지 않도록 다음 일반 실행까지 제거를 미룬다.
  새 로그인 항목은 기존 KeepAlive의 크래시 후 자동 재실행을 제공하지 않는다.
  업데이트 후에는 `open`으로 재실행한다. 기존 `kickstart`의 성공은 작업 제출 성공만 뜻해서 앱이
  뜨지 않아도 재실행 루프를 끝냈다. `LoginItemTests`와 `UpdateCheckerTests`에서 각각 마이그레이션과
  기존 작업 제출이 성공하더라도 앱 번들을 여는 경로를 검증한다.

- **로그인 실행을 LaunchAgent 로 등록하면 "등록하는 순간" 앱이 한 번 더 뜬다.** plist 의 `RunAtLoad` 는
  로그인 때만이 아니라 **에이전트가 로드되는 시점**의 실행을 뜻하고, `SMAppService.agent.register()` 가
  곧 그 로드다. 이전 구현에서는 설정 토글과 구 로그인아이템 사용자의 업데이트 첫 기동이 모두
  에이전트를 등록했다. 후자는 **사용자가 아무것도 누르지 않아도** 일어났다.
  **LaunchServices 의 중복 실행 방지를 믿지 마라** — GUI 로 여는 경로(Finder·`open`)에만 걸리고
  launchd 는 `Contents/MacOS/…` 를 직접 exec 한다. **피해는 아이콘이 아니라 상태다**: 두 인스턴스가
  `CompanionStore`·`UsageStore` 를 같은 파일에 각자 써서 저장이 last-writer-wins 가 되고, 진화·사용량이
  조용히 덮인다. 방어는 기동 지점 한 곳에서 판정하고
  (`SingleInstance` — 나중에 뜬 쪽이 물러난다) **메뉴바 항목을 만들기 전**에 둔다. 위치는
  `CrashReporter.install` **앞**이어야 한다: 뒤면 물러나는 인스턴스가 running 마커를 덮어쓰고 종료 시
  `markClean()` 이 발화해, 살아남은 쪽이 나중에 크래시해도 다음 실행이 정상 종료로 읽는다.
  물러나기 직전 로그는 `AppLog.writeAndFlush` 로 밀어낸다 — `write` 가 async 라 `terminate` 이 `exit(0)` 에
  닿으면 사라지고(실측 100회 중 42회), 그 줄이 없으면 가드 오작동("앱이 안 뜬다")과 크래시를 구별할
  단서가 없다. **대가를 함께 적어둔다: 물러나는 쪽이 launchd 소유라 살아남는 인스턴스는 워치독 밖이고,
  크래시 자동 재실행은 다음 로그인까지 꺼진다** — 메뉴바 앱은 로그아웃 없이 몇 주를 돌아 공백이 길다.
  반대 방향(먼저 뜬 쪽이 물러남)은 워치독을 즉시 지키지만 토글 직후 창이 사라져 크래시처럼 읽힌다.
- **프로세스 나이를 `NSRunningApplication.launchDate` 로 재지 마라 — launchd 가 exec 한 프로세스에선 nil 이다.**
  그 값은 LaunchServices 가 띄운 프로세스에만 기록된다. 하필 물러나야 할 쪽이 launchd 가 띄운
  인스턴스라, launchDate 로 판정하면 **가드가 통째로 무효인데 테스트는 전부 통과한다**(실측: 로그인
  에이전트가 띄운 인스턴스는 `launchDate == nil`, 같은 pid 의 `p_starttime` 은 정상). 커널
  `p_starttime`(`sysctl` `KERN_PROC_PID`)은 두 경로 모두에 남고 프로세스 간 비교도 성립한다.
  일반화: **판정을 순수 함수로 뺐어도 그 함수에 들어가는 입력이 무테스트면 결함은 입력 쪽에 산다** —
  입력을 읽어내는 층에도 가드를 따로 둔다. 회귀 가드: `SingleInstanceTests` 의 판정 8건 + 입력 3건
  (`testProcessStartTimeIsReadableForTheCurrentProcess`·`…IsPlausible`·`…IsNilForAnUnknownProcess`).
  시작 시각을 못 읽거나 같으면 아무도 물러나지 않는다 — 아이콘 하나 더 뜨는 것보다 둘 다 사라지는 쪽이 나쁘다.
- **async logger 는 exit 경로의 로거가 아니다.** `AppLog.write` 는 백그라운드 큐에 넣고 바로 돌아온다.
  같은 턴에 호출자가 `exit()` 에 닿으면 그 줄은 자주 사라진다(실측 100회 중 42회). 마커 파일처럼
  동기인 반쪽만 남으면 로그는 세션이 항상 비정상 종료된 것처럼 읽히고, **줄이 없다고 분기가 안 돈
  증거로 쓰면 안 된다**. `willTerminate` 의 `CrashReporter.markClean`(`clean shutdown`)과 중복 인스턴스
  yield 가 그 자리 — 둘 다 `writeAndFlush`(`queue.sync {}`). 판정은 주입된 sink 로 고정한다
  (`AppLogTests`) — `write` 는 `AppEnv.isBundledApp` 가드라 프로덕션 로그를 여는 테스트는 수정
  여부와 무관하게 통과한다. 부류 스윕: `write` 직후 `terminate`/`exit` 하는 자리를 전수하고
  `writeAndFlush` 로 묶는다. `AppLog.writeAndFlush` 는 테스트된 `backend.writeAndFlush` 를
  타야 한다 — `write()`+`flush()` 두 번째 쌍은 가드가 안 되고, `flush()` 만 빼면 스위트가
  초록인데 #174 가 다시 산다. (#174)

## 표시·UI

- **Floating-pet features share one click route and one bubble reservation.** Agent activity (#457)
  and pet interactions (#466) both changed the controller, hosting callbacks and sprite composition.
  Keeping either side of their conflict alone discards egg prayers or agent acknowledgement, or
  clips agent-only speech by reserving headroom only for limit alerts/hearts. Their original tests
  exercised each feature separately. Resolve the shared surface together: limit > agent done >
  agent waiting > hearts > hover/event; a plain click acknowledges agents before egg prayer or
  hatched-pet Open, while context-menu Open always opens. Keep the heart/particles attached to
  the sprite's bob modifier. `FloatingPetAgentTests` checks combined speech/headroom/event gates;
  `FloatingPetAgentWiringTests` invokes the production hosting callbacks for eggs and hatched pets.

- **초기 설정 이동은 애니메이션 완료에 의존하지 않는다.** 세션 키 만료·등록 안내에서
  `startExpanded`로 연 고급 섹션의 animated `scrollTo`가 비활성·non-key native 호스트에서
  반영되지 않았다. 원래 500ms 검사 시 clip Y는 0, 입력란의 host Y는 1483이었고, 입력 포커스만
  `NSSecureTextView`로 이동했다. 기준 버전과 최종 전체 게이트에서 재현됐지만 단독·선별 실행은
  통과해 원인을 좁히지 못했다. 호스트 크기 지정·명시적 표시·bitmap 렌더·화면 안 배치로는
  해결되지 않았고, 원래 테스트에서 애니메이션만 끈 대조 실험은 통과했다.
  → 초기 `proxy.scrollTo`는 바로 적용한다. 80ms 대기·대상 ID·상단 anchor·포커스·1회 진입 가드는
  유지하고, 사용자가 누르는 고급 섹션의 펼침 애니메이션은 바꾸지 않는다. 스윕한 컬렉션 로그의
  위치 복원은 이미 직접 스크롤하므로 대상이 아니다. 원래 `SessionKeySettingsRenderingTests`의
  500ms·viewport·슬라이더·navigation 검사를 유지한 focused 실행은 1건, 실패 0건으로 통과했다
  (1.266초). 실제 clip Y는 1312, 입력란의 host Y는 171로 화면 안에 들어왔다. `scrollTo` 한 줄만
  제거한 대조 실행은 같은 테스트의 기존 viewport 검사만 실패했다(1건, 실패 1건, 1.524초).
  재현 범위는 native 호스팅 테스트이며 설치 앱의 활성·key 팝오버에서 같은 실패를 확인한 것은 아니다.

- **화면을 if/else로 갈아 끼우면 내려간 쪽의 `@State`는 Back에서 돌아오지 않는다.** 도감 상세는
  `CollectionView`에서 격자와 포획 로그를 대신 차지한다. 그래서 Back을 누르면 `DexGridView`가 새로 만들어지고
  `page`가 0으로 돌아갔다. 3페이지에서 연 포켓몬도 Back 하면 1페이지였다. 포획 로그도 같은 분기라 스크롤이
  맨 위로 갔다. 필터는 `CollectionView`에 있어서 멀쩡했고, 페이지만 내려가는 쪽에 있었다.
  **왜 못 걸렀나:** 휠 페이징(#393)과 스프라이트→상세(#394) 테스트는 페이지 이동과 상세 진입을 따로 봤다.
  상세에서 Back으로 돌아오는 왕복 경로를 밟은 테스트가 없었다.
  → `CollectionView`가 방금 본 종(`dexReturnAnchor`)과 로그 행(`logReturnAnchor`)을 기억한다. 다시 만들어진
  격자는 그 종이 있는 페이지에서 시작한다(`DexScrollPager.page(containing:)`).
  로그는 그 행을 가운데로 스크롤한다. 앵커는 한 번만 쓴다. `LazyVStack`의 첫 `scrollTo`는 아직 안 잰 행
  높이를 추정치로 써서, 드러난 행이 측정되면 대상이 밀려 한 행 못 미친다. 그래서 측정이 끝난 뒤 한 번 더
  스크롤한다. 처음엔 한 턴(`Task.yield`) 미뤄 한 번만 스크롤했는데, 로컬은 타이밍이 맞아 통과했고 CI
  (macOS 15)에서 한 행 못 미쳐 실패했다. 스크롤을 한 번만 하도록 되돌리면 로컬에서도 실패한다.
  `scrollPosition(id:)`도 시도했지만 macOS 14 API(`anchor:` 없음)는 마지막 행을 맨 위로 올리려다 목록 끝을
  넘겨 빈 화면을 보였다.
  격자 앵커는 처음에 Back마다 썼다. 그런데 지우는 곳은 격자의 `onAppear`뿐이라, 로그로 돌아가는 Back
  (로그 행에서 열었거나 로그 세그먼트에서 Home 스프라이트로 열었을 때)에서는 남았다가 다음에 도감으로
  전환할 때 소비됐다. 그래서 Back이 격자로 돌아갈 때만 쓴다. 일회성 앵커는 소비할 화면이 확실할 때만 쓴다.
  또 처음엔 앵커를 격자의 `selectedID` 초기값으로 넣어 페이지를 계산했다. 그러자 #264 이후 화면에서 볼 수
  없던 선택 테두리와 하단 정보 줄이 Back마다 되살아났고, 스크롤만 돌려놓는 로그와도 달라졌다. 테스트가 이
  부수 효과를 "선택 유지"라는 의도된 동작으로 단언해서 리뷰에서도 못 걸렀다. 위치 복원용 값은 선택과 다른
  상태(`DexGridView.returnAnchor`)로 둔다.
  **부류 스윕:** 팝오버에서 목록→상세→Back 구조는 컬렉션 탭뿐이다. 설정과 리캡은 화면 전체를 덮고 닫으면
  Home 맨 위로 돌아오는 게 의도한 동작이라 대상이 아니다.
  **회귀 가드:** `DexBackNavigationTests`는 실제 `CollectionView`를 창에 띄우고 상세→Back 왕복 후 렌더된
  글자를 Vision으로 읽는다. 앵커 저장, 1회 소비, 로그 앵커를 각각 지우면 실패한다. 격자 앵커를 무조건 쓰게
  되돌리면 `testBackToTheLogLeavesTheGridOnItsFirstPage`가 실패한다. 앵커로 종을 다시 선택하게 하면
  `testBackFromDetailReturnsToThePageOfThatSpecies`가 하단 줄의 종 이름을 읽고 실패한다. 접근성 트리는 AX 클라이언트
  없이는 비어 있어 쓸 수 없다. Back은 AppKit `NSButton`이라 합성 마우스 다운을 보내면 추적 루프가 마우스 업을
  기다리며 멈추니 `performClick`으로 누른다. 화면 전환 직후엔 뷰 트리가 이전 화면을 히트 테스트해 누름이
  빠질 수 있어(CI), 화면이 바뀔 때까지 다시 누른다.

- **"재인증하라" 플래그는 성공뿐 아니라 "조회할 로그인이 없음"(nil) 에서도 내린다.** Cursor 401 뒤
  로그아웃·`CURSOR_USAGE_API=0` 이면 `fetch()` 가 던지지 않고 nil 을 주는데, 플래그 해제가
  `if let status` 안에만 있어 재로그인 안내가 재시작까지 남았다. 회귀:
  `testCursorAuthExpiredClearsWhenThereIsNoCursorLoginAnymore`. (#411)
- **겹치는 두 슬라이더는 서로의 순서를 지켜야 한다.** 경고(50…95)·위험(80…100) 임계가 겹쳐 경고 95 /
  위험 80 이 가능했고, 85% 창이 경고선 아래에서 "위험" 알림을 띄우며 경고 단계는 영영 발화하지 않았다.
  한쪽을 넘기면 다른 쪽을 한 칸(5) 밀고, 저장값도 로드 시 정렬한다. 회귀:
  `testWarningStaysBelowCritical`, `testStoredThresholdsLoadInOrder`. (#409)
- **한도 막대는 `LimitProgressBar`·`PaceTier.gauge` 한 경로로만 그린다.** Cursor 행이 자체
  `ProgressView(value: utilization)` 와 절대 임계색을 써서, 잔량 모드에서 라벨은 "80% 남음"인데 막대는
  20% 만 차고 색도 메뉴바·다른 탭과 달랐다. 새 행을 추가할 때 `quotaRow` 를 거치지 않으면 같은 부류가
  재발한다. 회귀: `LimitPaceTests.testEveryPopoverLimitBarFollowsTheDisplayMode`. (#407)
- **`L.t` 는 위치 인자라 옆 칸 문구를 붙여도 컴파일·자리표시자 검사를 통과한다.** 포르투갈어 칸에
  스페인어 "evolución" 이 두 곳 들어가 홈 카드에 그대로 노출됐다(#405). 같은 문구를 옆 언어에서
  복사할 때 생기는 부류라 소스 전체의 `t(` 호출을 스캔해 es/pt 전용 표지를 교차 검사한다.
  회귀: `LocalizationColumnTests`.
- **외부 응답 배열의 원소 하나가 전체 디코드를 죽이지 않게 한다.** Antigravity 쿼터의 `remaining` 은
  protobuf oneof 라 `remainingFraction` 이 빠진 bucket 이 온다. 필드가 non-optional 이라 한 bucket 때문에
  응답 전체가 throw → 모든 Antigravity 막대가 직전 값에 얼어붙었다. 빠진 bucket 은 "소진"이 아니라
  "알 수 없음"이므로 버리고 나머지는 디코드한다. 회귀:
  `testBucketWithoutRemainingFractionDoesNotDropTheResponse`. (#413)
- **Antigravity 그룹 표시명은 한 헬퍼로.** API 의 `displayName`("Gemini Models" 등)을 알림·사탕·
  펫 버블에 그대로 넣으면 앱 언어가 한국어여도 본문에 영어가 섞인다. 팝오버만 `L` 로 바꾸던
  분기를 `L.antigravityGroupTitle` 로 끌어올려 candy / `buildLimitWindows` / 팝오버가 공유한다.
  판정 축은 `gemini` · `claude|gpt|3p`(status 의 gemini/thirdParty 헬퍼와 동일). 회귀:
  `AntigravityGroupLocalizationTests`.

- **계속 쌓이는 로그는 정렬이 아니라 실제 화면 생성 비용을 검증하라.** 포획 로그의
  `ScrollView` + `VStack` 이 화면 밖까지 모든 행을 만들고, 각 `SpriteView.init` 이 동기
  `cachedImage` 를 호출했다. 268개 기록(진화 단계 이미지 579개)으로 초기 레이아웃을 재면
  이미지 조회 1,160회, 783~953ms였다. 디스크 캐시가 있어도 파일 읽기와 `NSImage` 생성은
  메인 스레드에서 반복됐다. **왜 못 걸렀나:** `testLargeDexSortPerformanceAndCorrectness` 는
  1,000개 기록의 정렬만 측정했다. 실제 데이터의 정렬·집계는 약 0.18ms라 결함 경로와 달랐다.
  → 로그만 `LazyVStack` 으로 바꾸고, `SpriteLoader` 의 동기·async 경로가 `NSImage` 객체 캐시를
  공유한다(`NSCache`, `countLimit = 64`). 키는 파일 경로로 종·일반/이로치·PNG/GIF·디렉터리를
  구분한다. 이미지 생성 실패는 이 캐시에 넣지 않고, 일반색 폴백은 일반색 키에만 둬 이로치를 가리지 않는다.
  `countLimit` 은 엄격한 메모리 상한이 아니며, 실제 프로세스 메모리 사용량은 별도로 측정해야 한다.
  **부류 스윕:** 같은 동기 로딩을 하는 아이템 아이콘에도 공유 캐시를 적용했다. 도감은 24칸 페이지,
  상점·가방은 고정된 아이템 종류별 행이라 같은 무한 증가 조건이 없고, 알 이미지는 이미 메모이즈한다.
  **회귀 가드:** `CatchLogRenderingTests` 는 실제 `CollectionView` 를 300개 기록으로 세 번 생성하고
  스프라이트 레이아웃 작업 수와 고정 높이를 검사한다. `VStack` 재주입 시 매번 1,200회로 실패했다.
  `SpriteImageCacheTests` 는 임시 파일의 생성 이미지로 객체 재사용·동시 로드·폴백·재시도를 검증하며,
  동기 캐시 히트를 제거하면 포켓몬과 아이템 테스트가 모두 실패한다. 외부 이미지나 실제 세이브는
  테스트에 포함하지 않는다. SwiftUI 워밍업 후 같은 268개 데이터/520pt 높이의 release 프로브는 초기 4행,
  22~25ms, 재진입 디스크 읽기 0회였다(클릭부터 화면 표시까지의 전체 시간과는 별도 측정).
  끝까지 스크롤 → 희귀도 필터 → 필터 해제 → 도감 전환·로그 재진입도 격리된 앱에서 확인했다.
  (사용자 리포트: 200개 이상 포획 로그 진입 지연, 2026-09-10.)
- **앱 언어와 시스템 로케일은 다른 축이다 — SwiftUI 가 스스로 만드는 문장은 로케일을 따른다.**
  `L` 문구는 `AppLanguage` 를 따르는데 `Text(_, style: .relative)` 는 `Locale.current` 를 따라, 한국어
  Mac 에서 앱을 영어로 쓰면 "Catch log" 옆에 "3시간 46분" 이 붙는 한 화면 두 언어가 된다. 팝오버 루트
  (`PopoverView.body`)에서 `.environment(\.locale, companion.language.displayLocale)` 로 내려 8곳
  (한도 7 · 포획 로그 1)을 한 번에 맞춘다. **`body` 안에서 줘야 한다** — `rootView` 조립 시점에 주면
  설정에서 언어를 바꿔도 팝오버를 다시 열기까지 안 바뀐다. 경계: 이 환경값은 SwiftUI 가 생성하는
  문장에만 걸리고 `TokenFormatter` 처럼 포매터를 직접 만드는 코드는 여전히 시스템 로케일을 쓴다
  (ko/en/ja 는 천 단위 구분자가 같아 차이가 안 보인다). 회귀 가드 `DisplayLocaleTests` 는 코드 비교로
  끝내지 않고 **그 로케일이 실제로 해당 언어의 상대 시각을 만드는지**까지 본다 — 코드만 비교하면
  `.current` 로 잘못 매핑해도 통과한다.
- **`.task(id:)` 키와 그 안의 재로드 가드는 같은 축 집합을 써야 한다.** 두 곳이 어긋나면 태스크는
  재실행되는데 안의 작업만 조용히 건너뛴다 — 실패가 화면에만 남고 로그엔 안 남는다. `SpriteView` 는
  `.task(id:)` 에 `종+shiny` 를 담고 내부 가드는 `loadedID`(종)만 비교해, 도감의 이로치 토글
  (종 고정·shiny 만 뒤집힘)에서 색이 바뀌지 않았다 — 재렌더 플래시를 막던 가드가 토글을 삼킨 것.
  판정은 순수 함수로 빼고(`SpriteView.needsReload` — `frameDelay` 와 같은 이유) 축마다 회귀 테스트를
  둔다(`SpriteShinyReloadTests`, 양방향 토글). 부류 스윕 확인분: `menuSpriteKey`("id-shiny" 포함)·
  `SpriteStore.cacheKey`(3축)·`DexEntryRow`(항목+언어) 안전 — `SpriteView` 만 결함이었다.
  같은 상태를 두 곳에 나눠 들면 재발하므로, 축을 늘릴 땐 `SpriteSubject` 처럼 주체 하나로 모으는 쪽이
  낫다(현재는 `loadedShiny` 가 subject 밖에 있어 반영 시점을 손으로 맞춘다).
- **지연 백필로 채워지는 데이터는 화면마다 트리거가 필요하다 — 새 화면은 그 트리거를 물려받지 않는다.**
  `DexEntry.names` 는 나중에 생긴 필드라 그 전 졸업분은 `nil` 이고, 포획 로그가 행이 뜰 때
  `dexResolveChainNames` 로 채워 왔다. 종 격자는 저장분만 읽어서 구버전 저장분이 `#41` 로 남았고,
  하필 격자가 기본 화면이라 로그를 눌러야 고쳐지는 상태가 됐다 — 자가치유가 *다른 화면*에 달려 있으면
  그 화면을 안 여는 사용자에게는 치유가 없다. 파생 화면을 새로 만들 땐 원본 화면이 하던 **조회·백필까지**
  같이 옮겼는지 본다(`DexGridView.task` → `backfillMissingDexNames`). 폴백(`#id`)은 저장하지 말 것 —
  저장하면 이름이 영구히 번호로 굳는다(`testBackfillRetriesAfterAnOfflineAttempt`).
  부류 스윕 확인분: 저장분을 읽는 소비자는 `DexEntryRow`(자체 백필 보유)와 격자뿐이고,
  `activeDexEntry`·`graduate()` 의 `line.names` 는 소비가 아니라 생성 지점이라 무관.
- **상태 뱃지의 문구와 판정은 같은 의미여야 한다.** 현재 개체에서 파생된 도감 칸은 알을 새로 사거나
  (`buyEgg` 는 `active` 만 버리고 `dex` 는 안 건드린다) 메타몽이 리빌하면(`pathIDs` 가 통째로 교체)
  사라질 수 있다. 이를 설명하려고 졸업 기록이 없는 모든 도달 단계에 `키우는 중`을 달면, 진화 뒤 이전
  형태까지 동시에 키우는 포켓몬처럼 읽힌다. `키우는 중`은 저장 안정성이 아니라 현재 상태를 뜻하므로
  `id == active.currentID` 인 현재 형태 한 칸에만 표시하고, 지나온 형태에는 아무 뱃지도 표시하지 않는다.
  이전 형태의 휘발성을 안내해야 한다면 `키우는 중`을 재사용하지 말고 별도 개념으로 설계한다. 회귀는
  2단계 도달 상태의 `[false, true]`, 졸업한 라인을 다시 키우는 상태의 `[false, true, false]`, 현재 개체가
  없는 졸업 기록의 전부 `false`를 함께 고정한다.
- **뱃지로 설명하려던 휘발성은 애초에 없애는 게 답이었다.** 위 항목이 남긴 숙제 — "이전 형태의 휘발성을
  안내해야 한다면 별도 개념으로" — 의 결론은 새 뱃지가 아니라 **휘발 자체를 제거**하는 것이다. `buyEgg` 가
  `active` 만 버리고 `dex` 를 안 건드린 탓에, 현재 개체에서만 오던 종이 통째로 도감에서 빠져 종 수가 줄었다.
  수집 화면이 "쌓이기만 한다"는 약속을 주는데 이게 그 약속을 깨는 유일한 경로였다. 이제 놓아준 개체를
  `releasedAt` 을 단 `DexEntry` 로 `state.dex` 에 남긴다 — 도감(`dexSpecies`)이 `state.dex` 를 접으므로 종
  보존은 자동으로 따라오고, 포획 로그만 `놓아줌` 뱃지로 졸업분과 구분한다. 규칙 셋: ① **도달분만 기록**
  (`pathIDs.prefix(stageIndex + 1)` — `plannedPathIDs` 를 쓰면 알을 사서 포기하는 게 도감을 채우는 지름길이
  된다) ② 이로치는 `currentIsShiny`(위장 메타몽은 리빌 전까지 숨김 — 놓아주기가 리빌 수단이 되면 안 된다)
  ③ `collectedFinals` 는 그대로 — 끝까지 키운 게 아니므로 최종체 완성·분기 가중에 넣지 않는다.
  `releasedAt == nil` 이 곧 "졸업분"이라 구버전 저장분에 마이그레이션이 필요 없다. 부수 효과로, 놓아준 종을
  가리키던 **대표 선택이 이제 유지된다**(예전엔 종이 사라져 `reconcileRepresentativeSelection` 이 해제했다).
  가드: `testReleasedSpeciesStaysInTheDex`·`testReleasingMidChainCreditsOnlyReachedForms`·
  `testReleasingDisguisedDittoKeepsShinyHidden` — 기록을 빼거나 `plannedPathIDs` 로 바꾸면 실패한다(주입 확인).

- **위장 메타몽 이로치 숨김은 표시 경로 전부가 같은 판정을 써야 한다 — `MonState.displaysShiny`.**
  규칙은 `currentIsShiny`·`ownsShinySpecies` 에 손으로 두 번 적혀 있었고, 세이브 스냅샷(`SaveSnapshotManager`
  의 생성·목록·구버전 파일 경로 3곳)은 원값 `active.isShiny` 를 읽었다. 설정 → 스냅샷 행이
  `SpriteView(shiny: snapshot.currentIsShiny)` 로 위장 종을 이로치로 그려 리빌을 미리 누설했다.
  **왜 못 걸렀나:** 숨김 테스트는 `CompanionStore` 경로(홈·놓아주기·도감)만 봤고, 스냅샷은 `CompanionState` 를
  직접 받아 store 를 거치지 않는다 — 새 표시 경로가 규칙을 재구현하지 않고 원값을 읽어도 막을 장치가 없었다.
  **수정:** 판정을 `MonState.displaysShiny` 하나로 모으고 store·도감·스냅샷이 모두 그것을 쓴다.
  `graduate` 의 `DexEntry(isShiny: a.isShiny)` 는 저장값(표시 아님)이라 원값이 맞다.
  **회귀 가드:** `SaveSnapshotTests.testSnapshotDoesNotRevealShinyOfDisguisedDitto` — 생성·목록·구버전 파일
  3경로와 리빌 후 공개를 확인. 수정 전 4건 실패 확인.

- **컴팩트 표시는 오늘 사용한 프로바이더만.** 메뉴바(`menuLines`) 등 좁은 표시에서 한도·상태를 보일 땐
  `snapshots` 의 오늘 토큰>0 으로 게이트한다 — 설치만 되고 오늘 안 쓴 프로바이더(Codex 등)를 노출하지
  마라(#56 "미사용 프로바이더 탭" 계열의 표시 버전). 팝오버 상세 뷰는 전체 노출 유지(의도된 상세). 함정:
  Claude 한도(OAuth)·Codex 한도(프로세스)는 *설치/인증만 돼 있으면 오늘 사용과 무관하게 값이 존재*하므로
  `limits != nil`/`codexLimits != nil` 만으로 표시하면 미사용 프로바이더가 샌다.
- **다중 토글 UI 레이아웃은 조합표 전수로.** 토글/입력이 여러 개인 표시 레이아웃을 바꿀 때, 사용자
  지시가 여러 메시지에 걸쳐 진화하면 각 지시를 **전체 대체가 아니라 특정 조합(행)에 대한 제약**으로
  누적한다. 구현 전 **모든 토글 조합 → 기대 출력 표**를 만들어 누적 지시와 대조·확인하고, 각 조합을
  테스트로 고정한다(`testMenuLinesAllCombinations` 처럼). — 회귀: "토큰+비용 세로로"(2개 활성 케이스
  지시)를 전역 규칙으로 오해해 "3줄 금지"(3개 활성 케이스 제약)를 깨고 3줄을 만든 사례. 두 지시는 서로
  다른 조합에 관한 것이라 **둘 다 성립**해야 했다(2개→세로, 3개→토큰·비용 한 줄+한도 아랫줄). 최신
  지시가 이전 제약과 충돌해 보이면 조합별로 재조정하고, 못 풀면 조합표로 되물어라.
- **수동 관찰(withObservationTracking) 표면은 companion 직접 변이 경로까지 추적해야 한다.** SwiftUI
  표면(팝오버·플로팅 펫)은 읽는 속성을 자동 추적하지만, AppKit 수동 관찰(`AppDelegate`)은 *등록한 속성만*
  본다. 메뉴바 스프라이트 갱신이 `observeStore`(=`store.menuTitle`)에만 걸려 있으면 store 틱 없이
  companion 만 바뀌는 경로 — 사탕 진화·졸업(`useRareCandy`), 세이브 가져오기(`applySave`),
  `hatchIfNeeded`·`revealDitto` 의 async 완료 — 는 다음 사용량 폴링(기본 120s)까지 이전 포켓몬이
  메뉴바에 남는다(사탕 졸업 직후 잔상 리포트). 같은 부류의 선례가 `UsageStore.onRefresh` 주석(한도
  변경이 menuTitle 미변경으로 companion 에 안 전달)이다. 표시가 파생되는 원천(`currentSpeciesID`·
  `currentIsShiny`)을 직접 추적하는 관찰 루프를 별도로 건다(`AppDelegate.observeCompanionSprite`).
  회귀 가드: `testCandyGraduationFiresSpriteIdentityObservation` — AppDelegate 쪽 배선은 AppKit
  (NSStatusBar)이라 헤드리스 테스트 불가, 관찰 계약(변이가 발화하는지)을 CompanionStore 쪽에서 고정.
- **메뉴바(상태아이템) stale dim 금지.** 시간 기반 stale(=`isStale`)로 `appearsDisabled` 를 켜면
  슬립/런치 직후 refresh 완료 전 몇 초간 메뉴바가 회색이 돼 '고장/비활성'으로 오인된다(사용자 반복 지적,
  `&& lastUpdated != nil` 로 런치만 막는 건 슬립-후 stale 을 못 막음). '오래됨' 신호는 팝오버에서만.
- **UI 변경 → 스크린샷 stale** 은 `release.sh` 가 자동 경고(`CLAUDE.md` §릴리스) — 통과의례화 방지.
- **번역 가드는 "이미 표에 있는 문구"만 본다 — 표에 *못 들어간* 문구는 구조상 안 보인다.**
  `LocalizationInterpolationTests` 는 `L(lang)` 을 거친 문자열의 `\(...)` 보간이 언어마다 살아남는지
  검사한다. 그래서 `Text("Antigravity 세션 갱신 필요")` 처럼 애초에 `L` 을 안 거친 리터럴은 통과한다 —
  #210 이 이 경로로 한국어 3줄(`PopoverView` 세션만료 안내)을 넣어 전 언어 사용자에게 한국어가 보일
  뻔했다. 가드가 답하는 질문("번역이 인자를 지켰나")과 결함의 질문("이 문구가 번역 대상이긴 한가")이
  다른 층이다. 그래서 표를 검사하지 말고 **소스를 스캔**한다(`LocalizedUILiteralTests`):
  `Sources/PokeTokenBar/UI/**` 의 문자열 리터럴에 한글이 있으면 실패. 한국어 *주석*은 하우스 스타일이라
  허용해야 해서 정규식이 아니라 문자 순회로 문자열/주석 상태를 추적한다 — `"https://x//경로"` 처럼
  리터럴 안의 `//` 를 주석으로 오인하면 진짜 결함을 놓친다(역검증에서 이 케이스로 반증함).
  새 프로바이더 UI 를 붙일 땐 같은 부류의 형제 문구(여기선 `claudeAuthExpiredTitle/Hint`)를 먼저 찾아
  문안 구조까지 맞춘다 — 문구만 새로 지으면 같은 화면에서 두 안내가 다른 말투로 갈린다.
- **`localizedCaseInsensitiveContains` ignores case, not diacritics.** Pokédex and Catch Log search
  promised accent-insensitive names but each screen had its own matcher built on it, so "flabebe"
  missed Flabébé; the tests only searched ASCII names. Name search goes through the one shared
  `CompanionStore.DexSearchMatcher` (`.caseInsensitive` + `.diacriticInsensitive`), and any new
  searchable list reuses it instead of adding a matcher. Guard:
  `testNameSearchIgnoresCaseAndDiacriticsInPokedexAndCatchLog` queries both screens.

- **팝오버 세로 `ScrollView` 는 콘텐츠 안쪽에 스크롤러 레인을 비운다 — `.reservesScrollerLane()`.**
  홈 탭을 `ScrollView` + 고정 520pt 로 감싸자(상점·가방·도감과 같은 높이), 오른쪽 끝에 붙은 수치(오늘 비용·Peak·추이 막대
  "오늘" 칸)를 스크롤러가 가렸다. 두 경로가 있다: ① 얇은 오버레이 스크롤러(기본)는 스크롤 중 콘텐츠
  위에 뜬다 — 상점·가방·도감 카드의 "구매" 버튼 끝도 같다. ② "스크롤 막대 항상 표시"에선 SwiftUI 가
  **넘칠 때만** legacy 거터(~15pt)를 예약하는데, 홈 콘텐츠가 520pt 보다 짧으면(실측 477.5pt) 거터 없이
  332pt 전폭으로 깔리고 빈 트랙이 그 위에 그려진다.
  **왜 못 걸렀나:** 고정 높이 변경은 "팝오버가 화면 밖으로 넘친다"만 검증했고, 스크롤러와 콘텐츠의 겹침은 어떤
  테스트도 보지 않았다. 오버레이 스크롤러는 스크롤할 때만 보여 정지 스크린샷에도 안 잡힌다.
  **수정:** 스크롤바를 숨기지 않는다(`.scrollIndicators(.never)` 는 스크롤 위치 단서를 없애고,
  사용자가 고른 "항상 표시" 설정을 무시한다). 대신 스크롤 콘텐츠에 trailing 12pt 를 항상 비운다
  (`PopoverMetrics.scrollerInset`) — 스크롤 여부와 무관하게 비워 탭 간 폭이 같다. 설정은 자체 16pt
  패딩이 있어 제외.
  **함정:** `.contentMargins(.trailing, _, for: .scrollContent)` 는 안 된다 — AppKit 이 오버레이
  스크롤러를 콘텐츠 인셋만큼 안쪽으로 옮겨 여전히 텍스트 위에 뜬다(렌더로 확인). 반드시 콘텐츠 **안쪽**
  패딩이어야 한다. 또 스크롤 안에서 폭을 고정하는 자식은 `scrollContentWidth` 를 써야 한다 — 제안 폭보다
  넓은 자식 하나가 열 전체를 다시 전폭으로 넓힌다(`frame(width:)`·`minWidth` 332 자식으로 재현).
  진화 라인의 현재 셀 폭(홈 310pt·도감 302pt)으로는 이 범위에 안 들어 실제 오버플로는 없지만, 페이징
  폭·페이드가 실제 보이는 폭과 맞도록 `scrollContentWidth` 로 바꿨다.
  **회귀 가드:** `ScrollerLaneTests` 가 `Sources/PokeTokenBar/UI` 의 모든 세로 `ScrollView` 가 자기
  클로저 안에서 `.reservesScrollerLane()` 을 쓰는지 괄호 매칭으로 검사한다(주석·문자열 제외, 바깥에 붙인
  패딩은 스크롤러까지 밀어 불인정). 다섯 곳 각각을 빼면 해당 `파일:줄` 로 실패하는 것을 확인했다.
- **A view that sets the cursor must reset it when it disappears, not only when hover ends.** Dex
  links (#394) used `.pointerStyle(.link)`. Clicking one navigates the link away while the pointer is
  still on it, so no hover-ended event arrives and the hand cursor stuck on the next screen. Nothing
  caught it: hover can't be synthesized in tests (offscreen `mouseMoved` events don't drive SwiftUI
  hover), and the PR screenshots were offscreen renders with no cursor. `DexEntryLink` now sets the
  cursor from `onContinuousHover` and resets it in `onDisappear` (only if it set it), via the pure
  `DexEntryLink.cursor(after:wasHovered:)`. **Regression guard:** `DexEntryLinkCursorTests`; with the
  disappear reset removed, it fails.
  **Test trap:** in the test process `NSCursor.arrow` compares equal to `nil` (`nil == .arrow` is
  true), so an `XCTAssertEqual` on `NSCursor?` passes no matter what. Decide with a plain enum and map
  to `NSCursor` only at the call site.

- **숫자 표기 구간은 원값이 아니라 반올림된 문자열로 판정한다.**
  `TokenFormatter.percent` 는 `value == value.rounded()` 로 정수 여부를 보고 아니면 `%.1f` 를 찍었다 —
  79.96 은 정수가 아니라 `%.1f` 로 가서 "80.0%" 가 됐다(88% 는 "88%" 인데 80% 만 소수점). `costCompact` 도
  `usd < 100` 을 원값으로 판정해 99.96 → "$100.0", 9 999.6 → "$10000"(K 구간 대신 5자리)이 나왔다.
  Cursor `usedPercent`·잔여 모드 `100 − x`·리캡 증감 `abs(delta)*100`·토큰 단가 기반 비용은 전부 임의의
  소수라 메뉴바·팝오버·알림에 실제로 나온다.
  **왜 못 걸렀나:** `testFormatterEdges` 는 구간 한가운데 값(88, 88.35, 9.54, 311.4)만 넣었다. 반올림이
  구간 경계를 넘는 값(x.95 이상)이 없으면 "판정 후 반올림" 순서 결함은 보이지 않는다.
  **수정:** 먼저 그 구간의 정밀도로 포맷하고, 그 문자열(파싱값)로 구간을 고른다.
  **회귀 가드:** `testFormatterRoundingBoundaries` — 경계 직전·직후 쌍(79.96/79.94, 99.96/99.94,
  9 999.6/9 999.4). 수정 전 코드로 5건 실패 확인. 스윕: `L.difficultyValue` 도 같은 모양이지만
  `snapDifficulty` 가 유효숫자 2자리로 스냅해 경계 넘는 입력이 존재하지 않아 손대지 않았다.

- **아이콘만 있는 `.plain` 버튼은 히트 영역을 명시한다(#379).** `.plain` 버튼은 라벨 프레임만 클릭되므로
  `Image(systemName:)` 하나를 라벨로 쓰면 글리프 크기(도감 셰브론은 약 7×12pt)가 곧 클릭 영역이라 자주
  빗나갔다. 라벨에 `.frame(width:height:)` + `.contentShape(Rectangle())` 로 최소 24~28pt 를 준다 —
  시각 위치를 지켜야 하면 바깥 음수 패딩으로 레이아웃 폭을 되돌린다(`DexPageButton`). 기존 렌더 테스트는
  픽셀·텍스트만 봤지 클릭 도달 여부는 안 봐서 못 걸렀다. **회귀:** `DexPageButtonHitAreaTests` 가 글리프
  밖·히트 영역 안 지점에 합성 마우스 이벤트를 보내 액션 발화를 확인한다. 스윕: 같은 형태의 나머지
  (`questionmark.circle` 키체인 도움말, 검색 지우기 `xmark.circle.fill`)는 채워진 원형 글리프라 라벨
  프레임이 이미 아이콘 전체라 제외.

- **창 크기에서 파생한 값은 저장된 크기를 되살린 뒤에 잰다.** 광장 목록의 칸 수를 `setFrameAutosaveName` 앞에서 재서
  창을 작게 저장해 두면 목록이 넘쳤다. 복원 중의 `windowDidResize`는 `window`가 아직 nil이라 고치지 못했다.
  **왜 못 걸렀나:** 칸 수 계산만 테스트했고 창을 여는 순서는 테스트하지 않았다. 테스트가 `SKView`를 만들지 않도록
  순서를 `restoreFrame`으로 빼서 고정했다. 가드: `testRosterCapacityUsesTheRestoredWindowHeight`.

- **An `NSTextField` left at its intrinsic height cuts off the tops of tall glyphs when the font's line is taller.**
  The plaza chat field (Galmuri 15) was pinned 9pt inside its bar, so it took its intrinsic height of 18pt while
  the font's line height is 21pt. The cell clips to its frame, so the top stroke of ㅎ in the placeholder was
  missing. The placeholder was also 385pt wide in a 336pt field, so its end was cut off on the right.
  **Why nothing caught it:** the chat input tests drove behaviour (Enter, Tab, Esc, cutting long text) and never
  measured the field, and the PR images showed the bar at a size where a missing 1–2px stroke is easy to miss.
  **Fix:** the field is as tall as the font's `defaultLineHeight` and sits 4pt lower so the glyphs are in the
  middle of the bar; the placeholder is shorter. `PlazaChatInputTests.testFieldIsAsTallAsTheFontsLine` and
  `testPlaceholdersFitTheField` fail with the old constraint and text. **Class sweep:** no other AppKit text field
  uses the pixel font. Chat bubbles and emote labels draw with CoreText into frames sized from the font, and SwiftUI
  `Text` sizes itself to the line. A new AppKit field with a custom font sets its height from the font's line height.

- **A status must be derived from what it means to the user, not from whichever field was at hand.** The plaza roster
  showed `inPlaza && !isIdle ? 접속 : 잠`. A teammate working with the plaza window closed was 잠 (asleep), a teammate
  whose Mac slept vanished instead of being 잠, idle was only measured while the idle person's plaza was open (so a
  closed plaza could never become 자리비움), and my own row was hard-coded 접속. The map's zZ and the minimap's dim dot
  used the same `!inPlaza` shortcut. **Why nothing caught it:** every test asserted the mapping the code already had
  (plaza closed → away) and the idle tests ran only with the plaza open. No test described the user's states.
  **Fix:** three states with their meaning written on `PlazaPresence`. 접속 means connected with recent input (plaza
  open or closed). 자리비움 means 5 minutes without input. `TeamRuntime.tickOnce` checks this whether or not the plaza
  is open, and `TeamSession.updateIdle` sends it. 잠 means the connection is gone; `TeamSession.asleepMembers` keeps
  these in memory, for the current team only. zZ and the dim dot mean idle only. **Guards:**
  `testPlazaClosedIsOnlineUntilIdle`, `testDisconnectedTeammateStaysAsleepUntilTheyReconnect`, `testMyRowShowsMyIdle`,
  `testIdleIsSentWithThePlazaOpenOrClosed`, `testFiveMinutesWithoutInputIsIdleOnTheNextTick` (each fails with the old
  rule injected). **Class sweep:** every reader of `inPlaza` was checked. The roster, the scene name, the minimap and
  the idle sender were fixed. The shelter placement and emote targeting still use `inPlaza`, because they are about
  where a teammate stands, not their status.

- **A narrow test filter hides the repository-wide guards; run the full suite before every commit.** A Hangul literal in a
  `Team/` source broke `TeamLocalizationTests`' no-Hangul guard (all team text lives in `TeamLocalization`). It slipped
  through because every task of the campfire branch ran a filtered `swift test --filter`, which excluded the guard.
  **Why nothing caught it:** the guard existed and was correct, but nobody ran it. **Capture:** the mechanism already
  existed: CI runs `scripts/test-gate.sh` (the full `swift test`) on every push and PR (`.github/workflows/ci.yml`). The
  gap was only the filtered runs during per-task work, so run the full suite before each commit too.
  **Class sweep:** the only filtered runs were the per-task ones on this branch; no other guard was skipped.

- **A render test must pin the scene clock and derive variants from a copy.** A photo test compared a render that carried
  the real time-of-day tint with variants rebuilt without it, and the scene clock was not pinned, so it failed only
  after 16:00 (dusk). **Why nothing caught it:** it passed all morning and afternoon, so the tint-free variants
  matched by accident. **Capture:** photo/scene render tests pin `now` (`PlazaPhotoTests.newScene` pins 2026-05-10 12:00),
  and variants are made by mutating a copy of the input, never by rebuilding it.
  **Class sweep:** every scene/photo test that compares renders pins `now` or compares variants made from one input (clean).
- **A `ForEach` id must be unique, and a hand-written list doesn't guarantee that.** `PlazaShortcutGuide`
  used `id: \.key`. The campfire row added a second `Space` key, and SwiftUI then drew the first
  `Space` row twice, so "모닥불 옆: 집중" appeared as "말 걸기". The list test passed because it read
  `entries`, not what was drawn. The row is gone now, and `testShortcutGuideKeysAreUnique` fails on any
  repeated key. **Class sweep:** the other hand-written lists used this way (`intervalPresets`,
  `rarityDisplayOrder`, the stat order, the board buttons) have no repeats, and the Claude root list
  drops repeats when it is built. The rest use enum cases, offsets or real ids.

- **Effect tests must assert where things go, not how many exist.** The pond droplets passed every count test while they
  drew a flat bar across the sprite (one shared vertical speed), and the rings sat under a wide sprite where nothing showed
  them; bubbles were hidden under a diver. Only an offscreen render showed it. **Why nothing caught it:** the tests counted
  particles and checked caps, which are true for a flat bar too. **Capture:** `PlazaPondLayerTests` read node positions and
  sizes (`testBigSplashFansOutAndRises`, `testRingsSitOnTheWaterlineAndGrow`, `testBubblesRiseAndFade`), each failing when the
  droplets share one height or the origin is the tile centre. For particle effects, read positions, sizes and z, and render
  the effect offscreen before calling it done. **Class sweep:** the weather layer already exposes `particlePositions`
  to its tests; the wet icon and the dust are single nodes placed from the foot point.

- **"키를 놓는다"와 "입력을 지운다"는 다르다 — 모드 진입은 쓰지 않은 탭까지 지운다 (사진 모드 PR #67).** `enterPhotoMode` 가
  `walker.releaseAll()` 을 불러, 걷는 중(0.15초 칸) 눌러 둔 방향 탭(`pendingTap`)이 남았다. 사진 모드가 시작된 뒤에도
  내 포켓몬이 한 칸 더 걸었다(spec 4.1 위반). **5-whys:** 증상(진입 뒤 한 걸음) → `releaseAll` 은 문서대로 탭을 남긴다 →
  이름이 비슷한 `clearInput()` 이 따로 있는데 진입 코드가 짧은 쪽을 골랐다 → **테스트는 서 있는 채 P 를 눌러서**
  탭이 비어 있는 경로로만 통과했다(트리거는 "걷는 도중 + 탭 대기"). **회귀 테스트:** `testATapPendingAtEntryNeverMovesMe` 가
  걷는 도중 방향키를 다시 눌러 탭을 남기고 진입한다(`clearInput` → `releaseAll` 주입 시 실패 확인).
  **부류 스윕:** `releaseAll` 호출처 전수(`PlazaScene` 의 `releaseAllKeys`, 창 키 상실, ⌘ 눌림): 창 키 상실·⌘ 는 키 뗌이
  오지 않는 상황에서 눌린 키만 놓으면 되고 탭은 사용자가 이미 한 입력이라 남기는 게 맞다. 입력을 아예 버려야 하는
  입력창 열기·판 열기·`canWalk` 해제는 이미 `clearInput` 이다. 새 모드로 "들어가며 입력을 넘기지 않는" 곳은 `clearInput`.

- **저장 값을 파생 값(잘린 값)으로 되쓰지 마라 — 되쓰는 건 그 값을 바꾸는 입력 한 곳에서만 (사진 모드 PR #67).** `layout()` 이
  지도 안으로 자른 틀 중심을 `photoCenter` 에 다시 써서, 모서리로 민 틀을 −로 줄였다 +로 되돌리거나 창 크기를 바꾸면 틀이
  제자리로 돌아오지 않았다(spec 4.3 "−/+ 는 중심을 유지"). **5-whys:** 증상(틀이 영영 이동) → 가장자리에서 방향키를
  계속 눌러도 위치가 쌓이지 않게 하려고 `layout()` 에 되쓰기를 넣었다 → 되쓰기의 목적은 "민 값을 쌓지 않기"인데 위치가
  입력 쪽(`update` 의 밀기)이 아니라 모든 레이아웃 호출 쪽이었다 → **기존 가장자리 테스트는 밀고 가만히 있는 경로만**
  밟아 확대·크기 변경이 값을 바꾸는지 몰랐다. **수정:** 밀 때만 "지금 보이는(잘린) 중심에서 시작해 더하고 자른 값을 저장".
  `layout()` 은 읽기 전용. **회귀 테스트:** `testZoomingOutAndBackKeepsAFramePannedToTheCorner`(모서리에서 2→1→2 뒤 틀 동일,
  되쓰기 주입 시 실패), `testHoldingAtTheEdgeDoesNotPileUp` 유지. **부류 스윕:** `layout()` 이 쓰는 `private(set)`/저장 프로퍼티
  (`photoFrame`, `visibleRect`, `photoShownCenter`)는 모두 레이아웃 결과 캐시이고 입력 값은 `photoCenter` 뿐이다.
  **같은 모드의 쌍둥이 결함:** 진입 때 틀 중심을 "화면 가운데"로 시드하면 위·아래 여백(24/44)이 달라 장면이 10pt 튄다.
  시드는 파생 값이 이어지는 쪽에서 역산한다 — `중심.y = visible.midY + (위 − 아래) ÷ (2·배율)`.
  `testEnteringKeepsTheViewAndFramesIt` 가 `visibleWorldRect` 불변을 단언한다(시드를 화면 가운데로 되돌리면 실패).

- **같은 규칙을 두 곳에 적지 마라 — 기하는 한 함수, 키 표는 한 꼬리 (사진 모드 PR #67).** 오버레이가 틀 사각형을
  `geo.size` 와 여백 상수로 따로 계산했고, 사진 모드 키 처리가 평소 키 처리의 Z/X/G·말풍선·확대 표를 통째로 복사했다.
  **왜 못 걸렀나:** 두 복사본이 오늘은 같은 값이라 모든 테스트가 통과한다 — 한쪽만 바뀌는 날에야 드러난다. **수정:**
  `PlazaPhotoFrame.viewRect(in:)` 를 `layout` 과 오버레이가 함께 쓰고(`testViewRectInWorldIsTheLayoutFrame` 가 뷰포트별로 월드
  변환이 `layout().frame` 과 같음을 단언, 한쪽 오프셋 주입 시 실패), 키는 `handleSharedKeyDown` 한 꼬리를 두 경로가 쓴다.
  **스윕:** `PlazaPhotoFrame` 상수를 쓰는 곳(`PlazaScene` 팬 속도, 오버레이 브래킷·안내 문구 위치)은 상수만 읽고 사각형은
  `viewRect` 만 만든다. 두 번째 키 표는 이제 없다.

- **사용자에게 하는 약속의 조건과 행동의 조건은 한 식으로 — 그리고 실패해도 신호는 간다 (사진 모드 PR #67).** 단체 사진
  카운트다운 문구는 "사진 모드인가"만 보고 "함께 찍는 중"이라 했지만 0 의 동작은 "사진 모드 **이고** 광장 창이 앞"이라
  뒤에 있으면 번쩍이기만 했다. 또 앞에서 찍던 사람의 `takePhoto()` 가 합성·인코딩·쓰기에서 실패하면 번쩍임이 아예 없었다
  ("모두의 화면이 0 에 번쩍인다"는 약속 위반). **5-whys:** 증상(약속과 다른 결과) → 문구 함수의 인자와 `finishGroupPhoto` 의
  분기가 서로 다른 입력을 봤다 → 이전 점검이 "문구는 사진 모드로 충분하다"고 판정했고 **테스트는 앞에 있는 경우만** 봤다
  (`frontmost = false` 는 0 의 결과만 단언하고 문구는 단언하지 않았다) → 실패 경로는 `photoWriter` 가 늘 true 였다.
  **수정:** 문구에 세 번째 상태("사진 모드지만 앞이 아님")를 더하고 키 창 변화(`handleBecomeKey`/`handleResignKey`)에서도
  다시 쓴다. `takePhoto()` 는 성공 여부를 돌려주고 실패해도 0 에 번쩍인다. **회귀 테스트:**
  `testTheCountdownSaysWhenThePlazaIsNotInFront`(새 문구, 키 창 변화로 되돌림), `testAFailedPhotoStillFlashesAtZero`(쓰기 실패 +
  번쩍임; `takePhoto` 결과를 무시하면 실패 확인). **스윕:** `isFrontmost` 를 읽는 곳과 `photoWriter` 를 부르는 곳을 전수
  확인했다 — 수동 Space 촬영은 사용자가 직접 누른 것이라 실패 시 번쩍임을 일부러 주지 않는다(성공했다는 신호이므로).

- **모드 전환·키 창 변화는 그 모드에서 파생되는 표시를 그 자리에서 갱신한다 (사진 모드 PR #67).** `photoModeChanged(false)` 가
  작은 지도를 다시 맞추지 않아, 사진 모드의 틀 영역이 최대 1초(다음 틱) 동안 지도에 남았다. 카운트다운 문구도 같은 부류다
  (키 창이 바뀌어도 다음 초 틱까지 옛 문구). **왜 못 걸렀나:** 테스트가 나간 뒤 지도 값이 장면과 같은지 봤지만 지도가
  **원래부터 따라가기 화면과 같은 값**이라 갱신이 없어도 통과했다(사진 모드 중 지도를 한 번 맞춰 둬야 트리거). 
  **회귀 테스트:** `testTheMinimapFollowsTheSceneRightAfterLeaving` 은 사진 모드에서 밀고 지도를 맞춘 뒤 Esc, 갱신 제거 시
  실패. **스윕:** `onPhotoModeChange` 구독자(`photoModeChanged`)가 HUD·힌트·카운트다운·지도를 모두 맞추고, `handleResignKey`/
  `handleBecomeKey` 가 카운트다운을 맞춘다.

- **같은 모서리의 HUD는 서로의 높이를 뺀다 (팀원 목록 페이지).** `PlazaRoster.capacity` 가 창 높이에서 여백만 빼서, 기본 창(640)의 목록이
  11칸까지 늘어나 시계와 작은 지도 뒤로 들어갔다. 둘은 목록보다 나중에 `addSubview` 돼 위에 그려지므로 실측으로 10명일 때 78pt, 13명일 때
  126pt가 겹쳐 10번째 줄과 "외 N명" 줄이 가려졌다. 둘은 클릭도 통과시켜 가려진 줄이 그대로 눌렸다. **왜 못 걸렀나:** `testCapacityFitsHeight` 는
  창 높이 산수만 봤고, 판 둘을 함께 배치해 본 테스트가 없었으며, 눈 확인은 팀원이 적을 때만 했다. **회귀 테스트:** `testPageFitsAboveTheClock`,
  `testRosterClearanceCoversTheMinimapAndTheClock`(실제 뷰를 재므로 `bottomClearance` 를 150으로 줄이면 실패 확인). **스윕:** 창 높이로 크기를
  정하는 판은 목록뿐이다. 왼쪽의 단축키 안내(펼치면 266pt)와 대화 기록은 고정 크기라 낮은 창에서 만날 수 있고, 이번에 고치지 않았다.

- **안 눌려야 하는 클릭은 눌리는 클릭과 같이 검사한다 (팀원 목록 페이지).** 호스팅 뷰를 고정 높이로 두자 SwiftUI가 내용을 가운데로 옮겨, 마지막
  페이지의 `>` 검사가 빈 곳을 누르고 통과했다. 비활성 단추를 고장 내도 그 단언은 잡지 못했다. 실제 창처럼 위쪽 제약으로 배치하고, 같은 클릭 묶음에
  살아 있는 쪽 화살표를 넣어 좌표가 머리줄에 닿는다는 것까지 증명한다(`testArrowIsDeadAtItsEnd`). **결함 주입은 기준 실행이 통과해야 뜻이 있다:**
  기준이 빨간 채 돌린 주입은 모두 "잡음"으로 나온다. 주입 스크립트가 기준을 먼저 돌리고 빨가면 멈춰야 한다. **SwiftUI 타이밍은 로컬 OS 결과로 판단하지
  않는다:** macOS 26 에서는 `.task` 안의 `await` 가 멈추지 않으면 호스팅 뷰의 첫 그림에 결과가 담긴다. 이 실험만 보고 첫 그림용 조회를 "필요 없다"며 지웠다가,
  macOS 15 CI 에서 `testRememberedIconDrawsOnTheFirstFrame` 이 빈 자리표시 색으로 실패해 되돌렸다. `.task` 가 첫 그림 뒤에 도는 OS 가 있으므로 `body` 에서
  메모리를 직접 본다. 같은 CI 에서 창 없는 호스팅 뷰의 `fittingSize` 는 모델이 두 번째로 바뀌어도 그대로였다. 크기를 재는 테스트는 경우마다 새 뷰를 만든다
  (`testRosterPanelHoldsOnePage`). 이 앱의 최소 버전은 macOS 14 라서, 지우는 근거가 로컬 실험뿐이면 CI 를 본 뒤에 지운다.

- **예약된 비멤버 장면 키(`PlazaDitto.sceneKey`)는 멤버를 향한 모든 UI 경로에 닿아야 한다 — 대상 찾기, 안내문, 메뉴, 따라가기 줄.**
  복사본은 `members` 에 없는 장면 키라서 장면의 `refreshInteractionTarget` 이 `memberTiles`(키 제외)만 보면 진짜 팀원 앞에서는
  "스페이스바를 눌러 X에게 말 걸기"가 뜨고 복사본 앞에서는 안 떴으며, `refreshHint` 가 `members[id]` 로 이름을 찾아 복사본을
  따라갈 때는 "X 따라가는 중" 줄도 없었다. 몸통박치기 없이 어느 쪽이 가짜인지 드러나는 결함이다. **5-whys:** 안내문이
  안 뜸 → 대상 표와 이름 표가 키를 몰랐다 → 메뉴·몸통박치기·인사 경로는 컨트롤러의 `targetTiles` 병합으로 이미 키를 알았고
  안내문 경로만 장면의 원래 표를 썼다(대상 표가 둘) → 왜 못 걸렀나: 복사본 테스트가 메뉴·인사·몸통박치기만 밟고 안내문은 보지
  않았다. 수정: 장면이 `targetTiles`(멤버 + 복사본일 때만 메타몽)를 한 곳에서 만들고 대상 찾기와 컨트롤러가 같이 쓰며,
  `hintName(of:)` 이 키를 따라 한 팀원의 이름으로 바꾼다(메타몽 모습은 안내문 없음). 가드: `testTheHintOnTheCopyIsTheHintOnTheRealMember`·
  `testFollowingTheCopyShowsTheFollowLine`·`testFacingTheDittoFormShowsNoHint`(장면 변경을 되돌리면 앞의 것이, 이름 변환을 되돌리면 둘째가 실패).
  부류 스윕: `members[`/`memberTiles`/`remotes[` 쓰임을 전수 확인했다. 몸통박치기를 받는 쪽(`showTackle`)과 `dittoWorld`·미니맵 점은
  진짜 팀원만 다루거나 복사본 점을 따로 더하므로 키를 일부러 빼고, 메뉴·카드·걷기·이모트·따라가기는 키를 이미 처리한다.
  새 UI 경로가 멤버를 이름으로 찾으면 키 처리가 필요한지 먼저 묻는다.
- **`NSHostingView` 안의 SwiftUI 뷰가 호버로 제 높이를 애니메이션하면 AppKit 이 제약 갱신을 되풀이하다 앱을 죽인다.** 광장 오른쪽
  팀원 목록 칸에 마우스를 올리면 칸이 아래로 늘어나게 했더니(#129) 앱이 튕겼다(2.5.633 크래시 리포트: `_NSViewUpdateConstraints` →
  `NSApplication _crashOnException:`). 목록의 호스팅 뷰는 Auto Layout(위·오른쪽 고정, 폭 제약)에 intrinsic 크기로 높이를 맡기는데,
  `.animation` 이 그 높이를 틱마다 바꿔 호스팅 뷰가 제약을 다시 무효화했다 — 오프스크린 실측으로 호버 한 번에 `updateConstraints`
  1000회 이상(애니메이션을 빼면 약 20회). 창의 뷰 수만큼의 추가 패스를 넘기면 AppKit 이 예외를 던진다. **테스트가 못 걸러낸 이유:** #129
  의 테스트는 `listLayout` 수식과 제약 없는 호스팅 뷰의 `fittingSize` 만 봤지, 제약에 묶인 호스팅 뷰의 레이아웃 주기를 돌려 본 적이 없다.
  수정: 호버로 크기가 변하지 않게 하고 오늘 한 일은 팀원 카드("오늘 광장")로 옮겼다. 가드: `PlazaRosterHoverLayoutTests` 가 실제와 같은
  제약의 호스팅 뷰에서 `updateConstraints` 횟수와 높이를 센다(오프스크린이라 실제 포인터 호버는 못 만들어서, 높이를 애니메이션하는
  변경을 되살리면 잡는 쪽이지 호버 자체를 재현하지는 않는다). 호스팅 뷰 안에서 크기가 바뀌는 UI(호버로 펼침·툴팁)를 더할 때는 크기를
  고정하거나 별도 오버레이로 띄운다.

- **윈도 팝오버 키트(Stage 7 Task 3): 창이 보이기 전에 숨긴 줄이 보였고, 150 % 글자 크기에서 줄 라벨이 0 px 로 눌렸다 — 둘 다 점검이
  못 봤다.** (출시 전, 키트 갤러리 캡처를 직접 열어보다 발견.) ① `WinKit.setVisible` 이 `IsWindowVisible(child) != visible` 로 바뀔
  때만 움직였는데, `IsWindowVisible` 은 조상 창이 숨겨져 있으면 자식에게도 false 다 — 팝오버는 보이기 전에 페이지를 배치하므로 그때
  "숨김"은 아무 일도 안 하고 `WS_VISIBLE` 이 남아, 창이 뜨면 숨긴 줄이 보인다. ② 컨트롤이 줄 폭 대부분을 차지하면(윈도 "텍스트 크기"
  150 %, 긴 링크) 라벨 폭이 0 이 됐다. **왜 못 걸렀나:** ① 갤러리 페이지에 숨긴 줄이 하나도 없어 그 가지를 밟지 않았다. ② 라벨이
  잘렸는지 보는 트리 점검이 *라벨 자기 폭에서* 글을 재서, 폭 0 에서도 `DrawTextW(DT_WORDBREAK)` 는 "한 줄"을 돌려줘 맞는다고
  판정했다 — 같은 측정이 원인과 판정을 함께 지나쳤다. **고침:** ① 창 자신의 `WS_VISIBLE` 비트로 판단. ② 라벨이 있는 줄에서 컨트롤이
  60 %를 넘으면 라벨을 위로 쌓는다(공유 `PopoverStackLayout`, 테스트). 점검은 "가장 긴 낱말보다 좁은 라벨"을 잡고, 네 가지 캡처
  (100 %, 144 dpi, 글자 150 %, 고대비) 모두 통과해야 한다. **스윕:** 남은 `IsWindowVisible` 은 최상위 창(광장 가림 판정, 광장 자가
  점검)에만 쓰여 그 창 자신의 상태다. **규칙:** 자식 창의 표시 여부는 `WS_VISIBLE` 로 판단하고, 키트 페이지는 숨긴 줄·넓은 컨트롤·큰
  글자로도 캡처해 본다. **회귀 점검:** `ui.kit.capture`/`ui.kit.tree` (갤러리의 숨긴 줄, 눌린 라벨) — 옛 `setVisible` 과 쌓기 없는
  배치를 되살린 실행에서 "a hidden row shows", "labels squeezed: 'Nickname' 37 px < its widest word 87 px" 로 실패함을 확인했다.
  **사후 리뷰 (같은 키트, 머지 뒤):** ① 60 % 규칙은 컨트롤 폭만 봤다 — 컨트롤이 60 % 아래여도 독일어·러시아어의 긴 낱말("Aktualisierungsintervall",
  "Предупреждение")은 125–150 % 글자에서 옆자리보다 넓다. 갤러리 라벨이 영어·한국어뿐이라 그 입력을 밟지 않았다. 고침: 라벨의 가장 넓은 낱말이 옆자리보다
  넓으면 쌓는다, 단위 스윕은 실제 `L` 설정 라벨 24 개 × 8 개 언어 × 글자 1/1.25/1.5 × 컨트롤 폭 5 가지를 GDI 로 잰다(규칙을 뺀 실행: 독일어·러시아어 14 줄
  잘림). 스윕 첫 판은 일본어 38 줄을 잘렸다고 했다 — 띄어쓰기 없는 일본어 구 전체를 한 낱말로 쳤는데 GDI 는 가나·한자 사이에서 줄을 바꾼다. 트리 점검의
  "눌린 라벨" 규칙도 같은 낱말 나누기를 써서 같이 고쳤다(`KitTree.unbreakableRuns`). ② 여러 줄 입력칸은 `DLGC_WANTALLKEYS` 라 대화상자 모드에서 Tab 을
  자기가 먹고(키보드 함정) Esc 에 부모로 `WM_CLOSE` 를 보내 페이지 창이 파괴됐다 — 갤러리에 여러 줄 입력칸이 있었지만 Tab/Esc 점검은 한 줄 입력칸으로만
  돌았다. ③ 그린 부품의 크기가 바뀌어도 페이지가 다시 배치되지 않아 다음 줄과 겹쳤다 — 갤러리 부품은 크기가 고정이라 그 가지가 없었다. **규칙:** 키트의
  모든 줄 종류(한 줄/여러 줄 입력칸, 크기가 변하는 부품)를 점검이 한 번씩 밟고, 라벨 규칙은 실제 번역 문자열로, 낱말 나누기는 언어의 줄바꿈 단위로 잰다.
  **회귀 점검:** `testNoSettingsLabelIsCutInAnyLanguageOrTextSize`, `testALabelWithAWordWiderThanItsRoomGoesAboveTheControl`, `ui.kit.multiLineKeys`,
  `ui.kit.partResize` — 각각 가드를 뺀 실행에서 실패를 확인했다.

- **윈도 팝오버(Stage 7 Task 4): 숨은 아이콘(^ 넘침 영역)에서 연 팝오버의 아래쪽을 넘침 플라이아웃이 덮었다.** (출시 전, 러너의
  실제 클릭 점검 캡처를 열어보다 발견.) 배치가 아이콘은 늘 작업 표시줄 띠(작업 영역 밖)에 있다고 보고 팝오버 아래끝을 작업 영역
  아래끝에 붙였다. 넘침 영역의 아이콘은 작업 영역 *안*의 셸 창(플라이아웃)에 있고, 러너(Server 2025)에서는 팝오버가 포그라운드를
  가져간 뒤에도 그 창이 맨 위에 열린 채 남아 팝오버 아래 45 px 를 덮었다 (Task 5 하단 줄의 자리). 사용자 PC 는 아이콘을 넘침
  영역에만 둔다. **왜 못 걸렀나:** 배치 단위 테스트의 아이콘·클릭 지점이 모두 띠 안에 있었다 — 테스트가 구현과 같은 가정을 했다.
  합성 `NIN_SELECT` 점검들도 셸이 준 사각형(넘침이면 띠 위의 ^ 버튼)을 썼다. ^ 를 실제로 눌러 연 플라이아웃 안의 아이콘을 실제로
  누른 `popover.realClick` 만 그 가지를 밟았다. **고침:** 작업 영역 안의 아이콘은 덮지 않는다 — 작업 표시줄 쪽으로 여백만큼 비킨다
  (공유 `PopoverPlacement.frame`). 윈도에서는 그 아이콘을 담은 작은 셸 창(플라이아웃) 전체를 비킨다 (열 때 한 번 찾고, DPI·페이지
  크기 재배치 때는 그 사각형을 유지). **스윕:** 아이콘이 띠에 있다고 가정한 곳 — 토글 가드의 아이콘 영역(이미 클릭 지점 기준,
  사각형이 클릭을 담지 않으면 클릭 둘레 상자), 트레이 메뉴(맨 위 창이라 무관). **규칙:** 트레이 아이콘 위치는 띠와 넘침 플라이아웃
  두 경우로 테스트한다. **회귀 점검:** `PopoverPlacementTests.testAnAnchorInsideTheWorkAreaIsNotCovered`, `popover.realClick`
  (플라이아웃 안 실제 클릭 → 열림, 그 창과 겹치지 않음).
  **부류 (병합 후 리뷰 I1):** 원인은 위치가 아니라 *맨 위(topmost) 창이 아닌 플라이아웃*이었다 — 넘침 플라이아웃도, 브라우저 PIP
  영상·회의 앱 미니 창·PowerToys "항상 위"도 맨 위 창이라 팝오버를 덮고, 덮인 곳을 누르면 그 창이 활성화를 가져가 팝오버가 닫힌다.
  첫 스윕은 배치만 바꿔 같은 부류의 다른 창을 놓쳤다. **고침:** 팝오버는 `WS_EX_TOPMOST` (활성화를 잃으면 닫히고, 하위 루프 때문에
  닫기를 미루는 동안에는 보통 띠로 내려간다; 소유 대화상자도 맨 위). **규칙:** 트레이 플라이아웃은 맨 위 창이고, 활성화를 잃으면
  즉시 닫혀 다른 앱 위에 남지 않는다. **회귀 점검:** `popover.aboveTopmost` (활성화 없이 띄운 맨 위 창 자리에서 연 팝오버가 그
  창 위에 있다; 다른 창이 활성화되면 닫히고 그 창이 다시 보인다), `popover.open` 의 `WS_EX_TOPMOST`.

- **윈도 팝오버: 홈의 톱니로 설정을 열면 창이 몇 초 동안 버벅이다가 설정이 섰다 — 보이는 창 안에서 페이지를 컨트롤 하나씩 지었다.**
  (사용자 PC 리포트 2026-11-17, 실제 GPU·원격 접속, 가져온 세이브·팀 코드·사용량 없음.) **직접 원인:** 페이지 교체
  (`WinPopover.replacePage`: 홈→설정, Back, 리캡)는 *이미 떠 있는* 팝오버 창에서 옛 페이지를 부수고 새 페이지를 지었다. 그 사이
  창은 그리기를 멈추지 않아 ① 정적 텍스트마다 `WM_SETFONT`(다시 그리기 켬)로 만든 자리(창 왼쪽 위 10×10)에서 바로 그려지고,
  ② 배치 패스마다 보이는 컨트롤 수백 개가 `SetWindowPos` 로 옮겨지며 부모를 그 자리에서 지우고, ③ 설정은 모든 줄을 보이게 배치한 뒤
  `sync()` 가 절반을 숨기고 다시 배치, 창 높이 변경(600→460 DIP)에 또 배치했다. 하나하나가 합성기가 화면에 낼 수 있는 중간
  그림이다. 러너(WARP)에서 잰 고치기 전 값(사용자와 같은 상태, `settings.openCost`): 클릭→정지 1406 ms, 빌드 1284 ms(배치 단계만
  571 ms), 배치 3 번, 빌드 *안*에서 보이는 창으로 보낸 그리기 메시지 35 184 개(지우기 18 713 — 컨트롤을 하나 옮길 때마다 부모 판이
  지워진다), 그리기가 든 60 Hz 프레임 85 개가 1.4 초에 걸쳐. 같은 페이지를 숨은 창에서 지으면(트레이 메뉴) 빌드 145 ms — 비용의
  거의 전부가 *보이는 창에서 지은 것*이었다. 실제 GPU·원격 화면에서는 그리기 한 번이 더 비싸 몇 초가 된다. **왜 못 걸렀나 (5-whys):** 처음 여는 길(`present`)은 창을 *보이기 전에* 짓기 때문에 이 비용이 없다 —
  교체 길은 같은 창을 재사용하면서 그 보장을 조용히 잃었다. `settings.*` 점검은 전부 트레이 메뉴처럼 `present(showSettings)` 로
  열어 숨은 창에서 지었고, 톱니 길을 밟는 유일한 점검 `home.settingsRoundTrip` 은 0.6 초 뒤 *결과 페이지가 설정인지*만 보고
  `PrintWindow` 로 최종 그림만 찍었다 — 시간·패스·그리기 횟수를 세는 것이 없었다. 러너는 WARP·로컬 세션이라 그리기 한 번이 싸서
  사람 눈에도 안 보였다. 유휴 게이트는 열린 뒤의 정지 상태만 잰다. **고침:** `WinKit.drawingOnce` — 보이는 창에서 페이지를
  짓거나 다시 짓는 동안 `WM_SETREDRAW` 로 그리기를 끄고, 끝난 뒤 `RedrawWindow(… ALLCHILDREN | UPDATENOW)` 로 한 번 그린다
  (`replacePage`, DPI·외형 `rebuild`, 설정의 자체 재빌드: 언어·팀 목록·스냅샷 목록·고급 폴더). 아직 안 보인 창은 건드리지 않는다
  (`WM_SETREDRAW` TRUE 가 창을 보이게 한다). 설정은 `sync()` 를 배치 *앞에* 두어 한 번만 배치하고, 높이만 바뀐 재배치는 줄을
  다시 놓지 않는다(`layoutIfNeeded`). 키트는 만들 때 `WM_SETFONT` 를 다시 그리기 없이 보낸다(새 창은 첫 `WM_PAINT` 에 어차피
  그린다) — 보이는 페이지의 구역 재생성(홈 한도 줄, 리캡 머리줄)도 만든 자리에서 깜박이지 않는다. 고친 뒤 같은 점검: 클릭→정지
  165 ms, 빌드 136 ms, 배치 1 번, 빌드 안 화면 그리기 0, 그리기 메시지 116 개가 프레임 3 개(51 ms)에. Back(설정→홈)은 빌드 안
  그리기 1 109→0·프레임 7→1, 리캡은 667→0·4→1. **스윕:** 보이는 창에서 컨트롤을
  만드는 길 — `replacePage`·`rebuild(dpi:)`·`WinSettingsPage.rebuildNow` 는 고침 대상, 홈·리캡의 구역 재생성(`removeRows` 후
  다시 만들기)은 `WM_SETFONT` 고침으로 즉석 그리기만 없앴고 배치는 다음 메인 큐 차례에 한 번 — 전체 동결은 하지 않았다(모델이
  바뀔 때마다 페이지 전체를 다시 그리면 열린 동안의 비용이 늘어난다). 팝오버 밖에는 키트 페이지가 없다. **영구 캡처:**
  `WinOpenTrace` — 페이지마다(열기·교체·재빌드) 빌드 수, 배치·새로고침 패스, 만든 창, 팝오버 창들의 그리기·지우기(빌드 *안*의 것
  따로), 단계별 시간, 마지막 변화 시각을 세어 페이지가 갈 때 로그 한 줄로 남긴다(이름과 숫자만, 타이머 없음) — 다음 사용자 PC
  로그가 무엇이 비쌌는지 말한다. 점검 `settings.openCost`(사용자와 같은 상태로 홈에서 톱니를 누름)와 `popover.swapCost`(Back,
  리캡)는 스레드 훅으로 모든 그리기 메시지를 세어 예산을 건다: 빌드 1 번, 빌드 중 *화면에 있는* 창의 그리기 0 (숨은 창이나 그리기를 끈
  창의 지우기는 아무것도 안 그린다 — 설정은 숨은 창에서 지어도 지우기 6 개를 보낸다), 그리기가 든 60 Hz 프레임 ≤ 4, 화면에서 줄을 옮긴
  배치 ≤ 1, 클릭→정지 ≤ 3 s, 단계 하나 ≤ 500 ms, 창이 열린 채 앞에 있고 합성기 프레임이 창 크기와 같음. **결함 주입:** 최종 코드에서
  `drawingOnce` 만 그냥 `body()` 로 바꾼 실행(scratch 브랜치, 지움)에서 두 점검 모두 실패 — 설정: 빌드 안 화면 그리기 34 884 개, 프레임 42,
  클릭→정지 689 ms; Back: 1 154 개·프레임 5; 리캡: 667 개. **규칙:** 보이는 창에서
  컨트롤을 한꺼번에 만들거나 다시 만드는 코드는 그리기를 끈 채 짓고 한 번 그린다. 페이지를 바꾸는 점검은 결과만 보지 말고 그 사이
  그린 횟수와 패스 수를 센다.

- **여름 물풍선이 터질 때 풍선 그림이 흩어졌다 (광장 터짐, 2026-11-21, fix 2 of plaza season art).**
  증상: 여름에 던진 물풍선이 터지면 풍선 그림(14×18) 하나가 조각 자리에 섞여 날았다. 직접원인: 터짐 조각의 glyph 표가
  `[공, 조각, 조각]` 한 목록의 색인이었고, 여름은 그 목록의 0번을 물풍선 그림으로 바꿔 끼웠다 — 터짐의 glyph 0(0단계의 가운데 조각,
  1단계의 바깥 조각)이 곧 풍선이 됐다. **왜 못 걸렀나:** 테스트가 조각들의 색 합집합과 터짐 기하(`burstPieces`)를 따로따로만 확인했고
  "여름 터짐이 무엇을 그리는가"는 아무도 보지 않았다. 던지기 장면 캡처도 첫 공이 땅에 닿기 전(프레임 5·12·20)에서 끝나 터짐이 한 장도
  없었다. **고침:** `PlazaSnowballArt.art` 가 `ball` 과 `burst`(항상 셋)를 따로 돌려주고 glyph 는 `burst` 만 가리킨다. **회귀 테스트:**
  `testTheBurstNeverDrawsTheBallPicture`(공 그림을 일부러 넘겨 터짐 내내 레이어가 그린 그림을 보고, 한 번도 그 그림이 아니며 glyph 0 은
  터짐 조각임을 확인), `testASeasonChangeMidBurstRedrawsWithTheNewPieces`(터지는 중 계절이 바뀌어도 새 조각으로). **결함 주입:**
  `resizeBurst` 가 glyph 0 에서 공 텍스처를 쓰게 하면 `testTheBurstNeverDrawsTheBallPicture` 가 "a burst drew the ball picture" 와
  "glyph 0 is a burst piece" 두 곳에서 실패, 되돌리면 통과. **스윕:** `grep -rnE "\[[0-9]\] = \(|textures\[0\]" Team/Plaza/` — 한
  목록의 한 칸을 계절별로 바꿔 끼우는 다른 광장 레이어는 없다(옛 `PlazaSnowball.swift`·`PlazaSnowballLayer.swift` 의 세 곳만 걸렸고 모두
  이 고침으로 사라짐). **규칙:** 한 목록을 "그림 목록"과 "색인표"로 동시에 쓰지 않는다 — 한 칸만 다르게 끼우고 싶으면 목록을 나눈다.

## 에너지 (상시 표시 애니메이션)

- **절전용 정지 상태는 짝 알림 하나에만 복구를 맡기지 마라.** `screensDidSleep` 이 폴링 타이머를 끄고
  `screensDidWake` 만 되살렸다. wake 알림을 놓치면 폴링이 영영 멈추고, 자정 `NSCalendarDayChanged` 갱신이
  남긴 빈 스냅샷(menuTitle "0", providers [])이 재시작 전까지 굳었다(#350, `lastError` 도 비어 무증상).
  **왜 못 걸렀나:** 정지/재개 경로에 테스트가 하나도 없었고, 실기기에서는 알림이 대개 짝지어 와서 재현이
  안 됐다. → 정지 중엔 5분 점검 타이머가 실제 디스플레이 상태(`CGDisplayIsAsleep`)를 보고 복구하고,
  `didWake`·모든 `refresh()` 진입도 같은 검사를 한다. 회귀 가드: `UsageStoreTests` 의
  `testSuspendedPollingProbe*`·`testSystemWakeResumes*`·`testRefreshWhileDisplays*`.

- **메뉴바 상태아이템 = idle CPU 저격수 (두 규칙 필수).** 실측: 라이브 앱 idle ~14% CPU → 수정 후 ~2%.
  ① **`statusItem.button.image` 대입은 반드시 `setDisableActions` 트랜잭션 안에서** (`AppDelegate.setStatusImage`).
  레이어 백드 `NSStatusBarButton` 은 이미지 대입마다 `NSStatusItemScene` 암묵적 전환 애니메이션
  (`updateSettings:transition:` → `NSAnimationContext runAnimationGroup:`)을 돌려 상태바를 재합성한다 —
  5fps 스프라이트 루프면 이 전환이 CPU를 먹는다. `CATransaction.begin()/setDisableActions(true)/commit()` 로
  즉시 반영해 전환을 없앤다(애니메이션은 유지). ② **`.transient` NSPopover 는 `contentViewController` 를
  평생 보유**해 닫혀도 `NSHostingView` 트리가 상주하며 매 디스플레이 사이클 재레이아웃된다(특히
  `Text(_, style:.relative)` 가 `requestUpdate` 로 self-invalidation → `StackLayout.placeChildren` 폭주). 위
  전환 CA 커밋이 이 레이아웃을 flush해 둘이 곱해진다. → `NSPopoverDelegate.popoverDidClose` 에서
  `contentViewController = nil`, 열 때 재생성(`buildPopoverContent`). ③ 메뉴 애니는 팝오버 열림 중 정지
  (`menuShouldAnimate` 에 `!popover.isShown`) — 팝오버 SpriteView가 이미 애니메이션하고, 트래킹 중 상태아이콘
  리드로우는 WindowServer 부하(데스크톱 비컨볼) 위험. **status-item 전용 앱은 occlusion 이 실제로 잘 안
  떠서**(앱이 status item 표시 중엔 occluded 안 됨) occlusion 게이팅은 보조 — 슬립/열림 게이팅이 실질 방어.
  검증 함정: bare/`open -n` 보조 인스턴스는 애니메이션이 안 돌아 14%를 **재현 못 함** → 실측은 설치된
  primary 앱 교체로만. **배터리(idle wakeup) 차원:** CPU% 낮아도 button.image 대입마다 레이어 dirty →
  CA 커밋 → WindowServer 디스플레이 사이클 왕복이 wakeup을 증폭한다(실측 ~47 wakeup/s). `setStatusImage`
  diff-gate(동일 프레임 객체 재대입 스킵 — 애니 프레임은 서로 다른 객체라 정상 통과) + GIF fps 하한
  (`AppDelegate.menuFrameFloor`, 당시 0.4s≈2.5fps) + `Timer.tolerance` 0.5(코얼레싱)로 ~5 wakeup/s(−89%),
  애니메이션 유지. **캡 값 자체는 튜닝 가능하고 0 만 금지**다 — 세 대책 중 CPU 14%의 주범은 CA 전환·팝오버
  상주였고 fps 캡의 몫은 wakeup 을 프레임 수에 비례해 줄이는 것뿐이다(22px 에서도 2.5fps 는 느리다는
  지적이 있어 값을 사용자 선택으로 열었다 — `UsageStore.AnimationQuality` 의 0.4/0.2/0.1. CA 전환이
  제거된 뒤라 14% 당시와 같은 조건이 아니다. 단 **fps 를 올리면 CPU 는 실제로 오른다**: 실측 idle
  0.2s/tol 0.5 = 1.8% → 0.1s/tol 0.1 = 5.1%(2.8배). "CA 전환이 주범이었으니 fps 는 공짜"가 아니라,
  주범이 사라진 만큼의 여유가 생긴 것뿐이다. 그래서 **기본값은 이 설정 이전과 같은 0.4s(powerSaver)**
  이고, 더 부드러운 쪽은 opt-in 이다).
  배터리-vs-AC/thermal 적응·CADisplayLink
  전환은 1인 로컬 노트북 기준 수확체감으로 판정, 미도입(필요 시 Agent Team 계획 참조). (Agent Team 조사 + 실측, 2026-07-22.)
- **프레임 교체는 `button.image` 대입이 아니라 `spriteLayer.contents` 로 한다 — 전환 억제와 다른 축이다.**
  `setDisableActions` 는 NSStatusItemScene *전환 애니메이션* 을 없앨 뿐, 대입 자체가 유발하는 **버튼
  재드로잉**(`NSViewBackingLayer display` → `_NSViewDrawRect`)은 그대로 남는다. 그 재드로잉에는 스프라이트
  22px 뿐 아니라 **2줄 attributedTitle 텍스트 렌더**가 통째로 포함돼, 5fps 루프에서 상시로 깔린다.
  프레임 픽셀을 전용 서브레이어(`AppDelegate.spriteLayer`)의 `contents` 로 넣으면 이미 업로드된 비트맵을
  바꿔 끼우는 것뿐이라 드로잉 경로를 아예 타지 않는다. `button.image` 는 폭 확보용 **투명 자리표시자**만
  두고(크기가 바뀔 때만 재대입) `imagePosition`·텍스트 배치·상태아이템 폭 계산은 AppKit 에 그대로 맡긴다.
  **실측** — ① A/B 프로브(같은 타이머·5fps·2줄 타이틀·60초×2라운드, `/tmp/ptb-probe.swift` 형태):
  `button.image`+CATransaction 2.00ms/프레임 · CATransaction 없이 3.51ms · **`layer.contents` 0.27ms**.
  ② 라이브 앱 `sample` 전후(메인스레드 샘플 비중): 타이머 경로 235/17212(1.37%) → 33/16581(0.20%),
  `CA::Transaction::commit` 163 → 14, `_NSViewDrawRect` 105 → **0**. 타이틀을 끄고 재면 2.00 → 1.43ms 라
  텍스트 렌더는 기여분의 일부일 뿐이고 나머지는 뷰 드로잉 왕복 자체다(= 텍스트만 손봐선 안 없어진다).
  `contentsScale` 은 화면이 아니라 **비트맵 자신의 픽셀/포인트 비율**을 따라야 한다 — 프레임은 `lockFocus`
  합성 시점의 백킹 스케일로 픽셀이 굳으므로, 화면에서 읽으면 1x 외부 모니터에서 스프라이트가 2배가 된다.
  **5-whys(왜 여태 안 보였나):** ① 14%→2% 를 만든 주범(CA 전환·팝오버 상주)이 워낙 커서, 남은 2% 는
  "프레임 수에 비례하는 어쩔 수 없는 비용"으로 읽혔다 — 실제로는 성격이 다른 축이 하나 더 있었다.
  ② 판정을 CPU% 로만 해서 "2% 면 충분히 낮다"에서 멈췄다. 콜스택을 뜨자 그 2% 안에서 드로잉 경로가
  단일 최대 항목으로 드러났다(추정이 아니라 `sample` 로 봐야 보이는 층). ③ fps·tolerance 처럼 *얼마나
  자주* 축만 튜닝 대상으로 보고, *한 번에 얼마나 비싼가* 축은 손댈 수 없는 상수로 취급했다.
  **회귀 방지:** 변환이 실패하면 `setStatusImage` 가 조용히 `button.image` 폴백으로 떨어져 애니메이션은
  멀쩡해 보이는 채로 절감만 사라진다(무성 실패) → `testMenuBarFramesConvertToLayerBitmaps` 가 전 스프라이트
  형태·bob 위상에서 변환을 못 박고, 빈 이미지로 **nil 이 실제 도달 가능함**까지 함께 단언한다(주입 검증).
  스케일은 `testSpriteContentsScaleFollowsTheBitmapNotTheScreen`. (실측 2026-09-01.)
- **fps 캡은 hold 가 아니라 decimate 다 — `max(floor, delay)` 는 애니메이션을 슬로모션으로 만든다.**
  프레임 delay 에 하한을 걸면(`max(floor, delay)`) 프레임 *수* 는 그대로라 각 프레임이 늘어나고, 결과적으로
  **루프 전체가 느려진다.** Gen-V 스프라이트는 55프레임×0.05s(=2.75s, 20fps)라 floor 0.4s 에서 22s 루프
  = **1/8 속도**가 됐다(메뉴바·플로팅 펫 둘 다). 올바른 적용은 누적 delay 가 floor 를 넘을 때만 프레임을
  내보내 **루프 길이를 보존**하는 것(`GIFDecoder.capFrameRate`) — 같은 wakeup 예산에서 속도가 원본이 되고,
  floor 0.4s 면 합성할 프레임이 55→6개로 줄어 오히려 가볍다.
  **5-whys(왜 안 걸렸나):** ① 원 근거가 "22px 에선 2.5fps 와 5fps 가 구분 안 된다"였는데 이는 *프레임
  레이트* 에만 맞는 말이고 *재생 속도* 8배 지연은 시야에 없었다. ② 테스트(`frameDelay(base:floor:)`)가
  **프레임 1개 단위**로만 검증해 — `max(0.1,0.4)==0.4` — 프레임이 55개 쌓였을 때 루프가 8배가 되는 걸
  구조적으로 볼 수 없었다(결함 트리거와 다른 경로로 통과하는 전형). ③ 2프레임 bob 은 늘리기와 솎아내기가
  같은 결과라 이 결함이 드러나지 않았고, bob 과 GIF 를 같은 하한으로 다룬 게 착시를 굳혔다.
  **영구 캡처:** 단일 프레임이 아니라 **루프 총 길이**를 단정한다(`testCapPreservesPlaybackSpeed` —
  옛 hold 방식 주입 시 11.0s/22.0s 를 잡고 실패 확인). 오용된 API `SpriteView.frameDelay` 는 제거했다.
  (사용자 리포트 "툴바 포켓몬이 팝오버보다 느리다", 2026-08-20.)
- **`Timer.tolerance`(및 `Task.sleep(tolerance:)`)는 곧 재생 지연의 상한이다.** tolerance 는 **늦게만**
  발화시킨다(Apple: "fire the timer later than the scheduled time, up to the tolerance"). 배수 0.5 는
  코얼레싱 강도가 아니라 "루프가 최대 1.5배까지 늘어져도 좋다"는 선언이었다 — 2.75s 루프가 최대 4.13s 가
  되어, `tolerance: .zero` 로 정확히 도는 팝오버와 나란히 보면 메뉴바만 느려 보였다(같은 리포트의 두 번째
  원인). 상시 애니메이션 표면에서 이 배수를 정할 땐 **wakeup 절약과 재생 지연을 같이 적어라** — 현재 0.1
  (지연 ≤10%). 가드: `testToleranceDoesNotVisiblyStretchPlayback`(>0 로 코얼레싱 유지 + 최악 지연 ≤15%).
- **항상 뜬 애니메이션 표면은 메뉴바와 같은 idle 규율을 공유한다.** 플로팅 펫(`FloatingPetPanel`)처럼 상시
  표시되는 두 번째 GIF 표면을 더할 땐 메뉴바 규율을 그대로 상속해야 회귀(#102 후속)를 안 만든다. **규율 =
  "캡이 존재한다(>0)"이며 값의 일치가 아니다** — 표면이 크면 같은 fps 에서도 끊김이 더 보여 값은 갈릴 수
  있다(현재는 두 표면이 사용자 설정 `UsageStore.AnimationQuality` 하나를 공유한다 — 표면별로 값을
  갈라야 할 근거가 생기면 그때 프리셋에서 표면별 값을 뽑아라): ① GIF fps 하한
  (`SpriteView(minFrameDelay:)` — 펫은 `store.animationQuality.frameFloor`, 메뉴바는
  `AppDelegate.menuFrameFloor`, 팝오버 등 *일시적* 표시는 0=네이티브) + `Task.sleep(for:tolerance:)` 코얼레싱, ② 저전력 모드 정적화(`FloatingPetController.shouldAnimate(lowPower:)`
  — `NSProcessInfoPowerStateDidChange` 관찰 후 콘텐츠 재구성), ③ 숨김/슬립 시 `contentView=nil` 로 프레임 루프 정지
  (팝오버 `popoverDidClose` 패턴). 회귀 가드: `FloatingPetEnergyTests`(fps 하한 clamp·`frameFloor>0`·팝오버 불변·
  low-power 정적화 순수 판정 — SwiftUI `.task` 타이밍 자체는 호스트 없이 xctest 불가라 순수 경로만 잠금).
  **가드 비대칭 주의:** 펫 캡만 상수로 잠겨 있었고 메뉴바 캡은 인라인 리터럴 `max(0.4, delay)` 여서
  *캡이 통째로 사라져도 테스트가 못 잡았다*. 지금은 두 표면이 같은 프리셋 값을 읽어 비대칭 자체가
  구조적으로 불가능하고, 가드는 프리셋 계약에 걸린다(`testNoAnimationQualityPresetDisablesTheCap`,
  `testTransientSurfaceIsTheOnlyUncappedOne` — 캡=0 주입으로 실패 확인). 상시 표시 표면을 더할 땐
  캡을 반드시 **이름 있는 값**으로 두고 `>0` 를 단정한다. occlusion 게이팅은
  all-spaces/`.floating` 펫이 실제로 거의 안 가려져 메뉴바와 동일 수확체감으로 미도입. (#102 리뷰 지적 반영, 2026-07-22.)

- **상시 입자 표면(광장 날씨)은 이름 있는 상한·`dt` 구동·재사용 노드로 만든다. 그리고 `DateInterval.contains` 는 끝을 포함한다.**
  날씨 입자(`PlazaWeatherLayer`)는 `maxParticles`(120) 상한, `update` 의 clamp 된 `dt` 로만 움직이고(타이머 없음, 창이 멈추면 같이
  멈춤), 날씨 종류·개수가 바뀔 때만 노드를 만든다(`testSpritesAreReusedAcrossFrames`). 하루 단위 캐시를 `DateInterval.contains`
  로 판정했다가 자정 0시(= 어제 구간의 끝)가 어제로 읽혀 새 날씨가 한 프레임 늦게 바뀌는 결함을 시험이 잡았다 — 끝을 뺀
  `date >= start && date < end` 로 비교한다(`testWeatherChangesWhenMidnightEntersANewWindow`, 주입 검증 완료).
  **5-whys:** 날짜 창 시험이 "하루 안의 시각"만 봤으면 못 잡았다 → 구간 경계 *바로 그 초*(23:59:59 → 00:00:00)를 넘는 시험이 필요하다.
  부류 스윕: 코드베이스의 `DateInterval.contains` 는 이 한 곳이다.

- **광장의 상시 틱은 일하는 쪽만 빠르게 돌린다 — 호스트가 아닌 쪽과 서 있는 쪽은 사건이나 마감에 깬다.** 메타몽 루프를 열린 광장마다
  0.05초로 돌려, 호스트가 아닌 Mac·가려진 창·가만히 선 호스트(대부분의 시간)도 초당 20번 깼다. **5-whys:** 상시 깸 →
  "한 틱이면 단순하다"고 모든 경우를 같은 간격으로 → 왜 못 걸렀나: 테스트는 루프를 손으로 넘기는 `LoopGate` 라 간격 자체를 보지
  않았다. 수정: 호스트가 걷는 중일 때만 0.05초, 서 있으면 두뇌의 `nextWake`(대기 끝·15분 한계·휴식 끝)까지 최대 0.25초, 호스트가
  아니면 1초(호스트 증발 대비용 안전망)이고 팀원 소식은 `observeMembers` 가 `advanceDitto` 를 바로 불러 반영한다. 간격이 길어져도
  걸음이 느려지지 않도록 두뇌는 걸음을 `now` 가 아니라 앞 걸음이 끝난 시각에서 시작한다. 가드: `testOnlyAWalkingHostTicksAtFiftyMilliseconds`
  (LoopGate 가 요청한 간격을 기록), `testAPresenceChangeMovesTheDittoWithoutALoopTick`(관찰 호출을 지우면 실패),
  `testAStepStartsWhereThePreviousOneEndedAtCoarseTicks`(되돌리면 실패). 상시 루프를 더할 때는 "이 틱은 누가 필요로 하나"부터 묻는다.

## 알림

- **Codex 사탕은 사용률 하락을 관측해야 다시 지급한다.** Codex는 구독 한도를 다 써도 credits로
  같은 세션을 계속 사용한다. 실제 로그에서도 credits 잔액이 감소하는 동안 주간 사용률은 100%,
  `resets_at`은 같은 값으로 유지됐다. 사용자는 이 상태에서 매 새로고침마다 사탕을 받았다고 보고했다.
  같은 epoch 반복 조회와 ±1초 지터는 #375의 `isNewEpoch`가 이미 막으므로, 보고된 반복 지급의 직접
  원인은 아직 확정하지 못했다. 다만 `evaluateCandyGrants`에는 리셋 시각이 창 규모(세션 30분, 주간
  24시간) 이상 전진하면 100%가 유지돼도 지급 기록을 지우는 경로가 남아 있다. #375 테스트도 Codex 키로
  큰 epoch 전진 시 재지급을 기대했고, credits 사용 중에도 그 기대가 맞는지는 검증하지 않았다.
  새 기준은 Codex primary와 secondary 창에 `epoch`를 넘기지 않아, epoch 변화만으로 지급 기록을 지우지
  않는 것이다. 판정 함수의 기존 계약(`epoch == nil`이면 사용률 하락으로만 재무장)을 그대로 쓰므로 별도
  플래그를 두지 않는다. 기존 세이브에 남은 Codex `candyWindowEpoch`는 더 읽히지 않는다.
  100% 미만을 관측한 뒤 다시 100%에 도달하면 지급한다. credits 보유 여부와 잔액은 지급 조건이 아니다. 앱 종료나 슬립 중 리셋과 재소진이 끝나 중간 사용률을 못 봤으면
  재지급하지 않는다. 최초 시드와 기존 지급 원장은 유지하고, 이미 지급한 사탕은 회수하지 않는다.
  스윕 결과 지급 기록 해제는 `CompanionStore`의 epoch 변경과 사용률 하락 두 경로에만 있고,
  `SaveTransfer`는 원장을 병합해 유지한다. Claude와 Antigravity는 기존 epoch 재무장을 유지한다.
  회귀 가드: `testCodexCreditsAtFullLimitDoNotRegrantWithoutUtilizationDrop`은 app-server 응답을 디코딩해
  `UsageStore → candyEligibleWindows → grantCandies`를 검증한다. primary가 주간인 실제 형태와
  primary=세션, secondary=주간 형태를 모두 다룬다. 잔액 감소, 동일 시각, 지터 왕복, 다음 epoch에서도
  추가 지급이 없고, 99%→100%에만 재지급한다. `testEligibleWindowsCodexOmitsResetEpoch`는 `resetsAt`이
  있는 응답에서도 Codex 창의 `epoch`가 비어 있는지 확인한다. 최초 시드, 재시작, 한도 조회 누락,
  재무장 영속과 Claude, Antigravity epoch 재지급도 별도 테스트로 검증한다. Codex 창에 `epoch`를
  되살리는 결함을 주입해 회귀 테스트가 실패하는 것을 확인했다.

- **사탕 재무장도 util dip 만 믿지 마라 — 창 epoch 를 같이 보되, 휘발성 지터에 재무장되지 않게 하라.**
  Codex는 위 사용률 관측 기준을 따른다. 지급 key 는 안정
  (`claude.fiveHour`)이어야 알림 dedup 과 같은 이유로 `resets_at` 을 key 에 넣으면 안 된다. 그런데
  재무장을 *오직* utilization&lt;100 관측에만 걸면, Mac 이 리셋 구간을 잠자거나 앱이 꺼져 있는 동안
  창이 바뀌고 다음 poll 이 다시 100%면 `candyGrantTier` 가 영원히 1 로 남아 "한도를 여러 번
  찍었는데 사탕이 안 온다"가 된다(#326). 해결: `candyWindowEpoch[key]=resets_at` 을 영속하고, 같은
  key 에서 epoch 가 바뀌면 util 과 무관하게 tier 를 비운 뒤 100%면 재지급. nil→첫 epoch 는 재무장이
  아니다(구세이브 업그레이드 폭탄 방지).
  **그러나 날 것의 epoch 문자열을 단순 `!=` 로 비교하면 안 된다**: Anthropic API 가 매 응답 새로 매기는
  마이크로초(`...00.928794` vs `...00.935515`)나 Codex app-server 의 ±1s 지터, 롤링 5h 창의 분 단위 드리프트로
  인해 매 poll(60초)마다 새 epoch 로 오판되어 100% 상태에서 사탕이 매분 무한 지급되는 결함이 터졌다.
  방지: ① `UsageStore` 에서 ISO8601 초 단위 정규화로 마이크로초 휘발성 제거, ② `CompanionStore.isNewEpoch` 에서
  타임스탬프 차이를 파싱해 창 규모(세션 ≥30분, 주간 ≥24시간) 이상 전진했을 때만 실제 리셋으로 인정(지터·1분 드리프트 차단).
  회귀 가드: `testRearmWhenWindowEpochAdvancesWhileStillAt100`·`testGrantAfterSeedWhenEpochAdvancesWithoutUtilDip`·
  `testLearningEpochForFirstTimeDoesNotRegrant`·`testVolatileMicrosecondEpochDoesNotRegrant`·
  `testCodexJitterEpochDoesNotRegrant`·`testRollingWindowMinorDriftDoesNotRegrant`·`testSessionFullResetWhileStillAt100Regrants`.

- **휘발성 필드를 dedup/identity 키에 쓰지 마라.** 매 fetch/refresh 마다 값이 변하는 필드(예: rolling
  한도 창의 `resets_at`)를 알림 중복방지 키에 넣으면 매번 새 키가 되어 dedup 이 무력화된다 — 주간 한도
  알림이 80·81·84…갱신마다 반복되던 회귀. 임계값 알림은 **엣지 트리거**(직전 tier 보다 높아진 순간만
  발화, 경고선 아래로 내려가면 재무장)로 구현하고, 판정은 부수효과(실 알림 전송·`.app` 번들 가드)와
  분리한 **순수 함수**(`UsageStore.evaluateLimitAlerts`)로 테스트한다 — 번들 가드 때문에 실 발화 경로는
  xctest 에서 조기 return 되어 커버 불가였던 게 무테스트의 원인.

## 상태 파일 이전·병합

- **상태 파일을 옮기거나 합칠 땐 "진행"과 "이 기기 장부"를 먼저 분류하라.** 같은 파일에 살아도 성격이
  다르다 — `usedSinceInstall`·`dex`·`inventory`·`candyGrantTier` 는 어느 기기에서든 참인 **진행**이고,
  `claimedTodayTokens`·`lastDate`·`installBaselineSet` 은 *그 기기가* 어디까지 적립했나를 적은 **로컬
  장부**다. 장부를 그대로 들여오면 옛 기기의 오늘 최고치가 문턱이 되어 `update` 의
  `todayTokens > claimedTodayTokens` 게이트가 이전 당일 내내 거짓 → 새 기기 사용분이 조용히 안 잡힌다
  (자정에 저절로 낫기 때문에 버그로 안 보인다). 반대로 계정 전역 근거로 만들어진 원장(`candyGrantTier`
  — 한도 창 key)은 **버리면** 같은 창에서 재지급된다. 이전·병합 경로를 만들 땐 필드를 전수로 이 두 부류에
  넣어 보고, 로컬 장부만 새 기기 기준으로 다시 잡는다(`SaveTransfer.rebasedForThisDevice`). 회귀 가드:
  `testTransferDayTokensStillCountAfterRebase` — 재정렬 없는 대조군을 같이 돌려 결함 조건이 살아 있는지도
  함께 확인한다(테스트가 트리거 브랜치를 실제로 밟는지 보증).
- **Read a rotated file into memory before any write that can prune it.** Snapshot restore took
  the pre-restore safety snapshot first; at exactly `maxSnapshotsToKeep` files that 11th snapshot
  pruned the oldest one, so restoring the oldest entry read a deleted file. The restore test only
  used two snapshots, below the retention limit where pruning never runs. Load and validate the
  selected snapshot first, then write the safety snapshot and apply the in-memory data; an
  unreadable selection must fail before anything is written or pruned.
  Guards: `testRestoreOldestSnapshotAtRetentionLimit`,
  `testRestoreUnreadableSnapshotLeavesStateAndSnapshotsUntouched`.
- **정규화는 "디코드 가능한데 쓰면 트랩인 값"까지 — 체인 내 중복 종 id.** `DexEntry.chainOrder`·
  `MonState.pathIDs` 에 같은 종이 두 번 들어간 세이브(손편집·외부 불러오기)는 디코드에 성공하지만,
  도감 이름 조회(`dexResolveChainNames` 오프라인·온라인 양쪽)·놓아주기·졸업이 그 배열로
  `Dictionary(uniqueKeysWithValues:)` 를 만들어 `Duplicate values for key` 로 앱이 죽는다. 디코드 성공이라
  `.corrupt` 복구도 안 걸린다.
  **왜 못 걸렀나:** `sanitized` 는 수치 트랩(토큰 상한·`totalForms`)만 다뤘고, 컬렉션 불변식(중복 없음)은
  "정상 플레이로는 안 생긴다"는 이유로 검사 대상이 아니었다 — 그러나 이 함수의 존재 이유가 손편집 입력이다.
  **수정:** `sanitized` 에서 `chainOrder`·`pathIDs`·`plannedPathIDs` 의 첫 등장만 남기고, `stageIndex` 는
  dedupe 전의 현재 종 위치로 다시 맞춘다. 디스크 로드·스냅샷 복구·불러오기가 모두 이 함수를 지난다.
  **회귀 가드:** `SaveTransferTests.testDuplicateSpeciesInSavedChainsAreRemovedOnLoad` — 수정 전엔
  `Fatal error: Duplicate values for key: '1'` 로 프로세스가 죽는 것을 확인.
  **스윕:** `CompanionStore` 의 나머지(`claimedTodayTokensByProvider` 키)는 딕셔너리 키라 유일하다. 세이브
  밖의 사용처(로그 스캔·PokéAPI 스탯)는 이 입력 경로가 아니라 범위 밖.

## 렌더 기하 (스프라이트·이미지)

- **Direct2D 의 `ID2D1Bitmap::CopyFromBitmap` 은 `BeginDraw` 안에서 쌓아 둔(배치된) 그리기를 먼저 실행하지 않는다.** (Stage 6 Task 4)
  윈도우 플라자 렌더러의 곱하기·곱하기X2(낮밤 색·모닥불빛·불꽃빛)는 스프라이트 아래 영역을 스크래치 비트맵으로 복사해 섞는데, 복사가 같은 프레임에서
  앞서 그린 지도·캐릭터를 못 보고 빈 프레임을 읽어 화면이 통째로 검게 나왔다(첫 CI: `dusk` 미리보기 전면 검정, SpriteKit 스와치 multiply·
  multiplyX2·daylight 가 50–254 차이). **왜 못 걸렀나:** 처음 쓰는 경로라 이전 테스트가 없었고, 같은 프레임의 색 혼합(스크래치에 그린 뒤 이펙트로 읽기)은
  D2D 가 순서를 지켜 줘 통과했다 — "D2D 가 의존성을 알아서 지킨다"는 가정을 그리기가 아닌 자원 API 에도 적용했다. 회귀 테스트(골든)가 첫 실행에서 잡았다.
  **수정:** 복사 직전 `Flush()`. **가드(기계):** `WindowsPlazaRendererTests.testSwatchesMatchSpriteKit` 의 multiply/multiplyX2/daylight 그룹,
  `testPreviewScenesRenderOnWARP`(캡처가 대부분 불투명이고 앞 캡처와 달라야 한다). **스윕:** `CopyFromBitmap` 은 `scene_device.cpp` 의 두 곱하기 경로(고침)와
  읽기(`EndDraw` 뒤라 안전)뿐이다. Task 8 캔버스의 multiply(영역 복사)도 같은 부류 — 복사 전에 `Flush()`.

- **최근접 샘플링의 경계 동점: WARP 는 픽셀 중심이 텍셀 경계에 정확히 걸리면 왼쪽(위쪽) 텍셀을, SpriteKit 은 화면 기준 오른쪽(아래쪽) 텍셀을 고른다.**
  (Stage 6 Task 4) 골든 `nearest 2x2 scale 3 x+0.5` 에서 Δ255, 좌우 반전 스프라이트에서는 시트 조각이 이웃 텍셀(테두리)을 끌어왔다. SpriteKit 규칙은
  화면 공간이다(반전돼도 오른쪽·아래가 이긴다, 픽셀 덮기의 좌·상 포함과 같은 규칙). **수정:** 픽셀 중심보다 1/256 기기 픽셀 오른쪽·아래에서 샘플하도록
  원본 사각형을 그 양만큼(변환을 거꾸로 거쳐 텍셀 단위로) 옮긴다 — 동점이 아닌 픽셀은 그대로다. **가드(기계):** 스와치 `nearest` 그룹,
  `testNearestSamplingAndEdges`(조각 테두리 번짐, 반전 포함), `testFractionalBackingScale`(1.25 배에서 동점이 많은 타일). 캔버스의 보간 없음 그리기와
  패널 이미지(Task 8·10)도 같은 규칙을 따라야 한다.

- **이미지에 붙인 GPU 캐시가 디바이스를 강하게 쥐면, 앱 수명 이미지가 닫은 창의 Direct3D 디바이스를 놓지 않는다.** (Stage 6 Task 5)
  Task 4 의 `WinBitmapRef`(`PlazaImage.backendCache` 에 붙는 텍스처 참조)가 `WinGfxDeviceHandle` 을 강하게 참조했다. 광장 컨트롤러는 지도·계절 그림·
  풀숲·얼음 그림을 프로세스당 한 번 만들어 `static` 으로 둔다(`cachedMapImage`, `cachedSeasonLooks` 등) — 창을 닫아도 그 이미지들의 캐시가 디바이스와
  WARP 스레드, 수십 MB 를 붙잡는다(결함 주입 실행: 닫고 10 s 뒤 사설 메모리 56.6 MB, 고친 뒤 34.2 MB). **왜 못 걸렀나:** Task 4 는 창 없는 오프스크린
  렌더러라 "닫기"가 없었고, 테스트는 매번 새 디바이스를 만들고 끝났다 — 수명이 앱과 같은 캐시와 수명이 창과 같은 디바이스가 만나는 경로를 밟는 점검이 없었다.
  **수정:** 참조를 `weak` 로 — 디바이스가 사라지면 그 비트맵도 함께 사라졌으므로 참조는 낡은 것이 되고, 다음 그리기에서 다시 올린다. **가드(기계):** 자가 점검
  `plaza.close`(닫은 뒤 디바이스 약한 참조가 nil, 사설 메모리 보고) — 강한 참조로 되돌린 결함 주입 실행(run 43696336004)에서 FAIL 확인. **스윕:** Windows 에서
  `backendCache` 를 채우는 곳은 `WinGfxDevice.bitmap(for:)` 하나다(캔버스는 쓰지 않는다). 규칙: 창·디바이스 수명의 자원을 가리키는 캐시는 그 자원을 약하게 쥔다.

- **`.resizable()` + `.frame(w:h:)` 는 "맞춤"이 아니라 "늘여 채움"이다.** 대조 없이 정사각 프레임에 넣으면
  비정사각 원본은 그대로 왜곡된다. 이 부류가 오래 안 잡힌 이유가 핵심이다 — **정적 자산이 전부 정사각이라
  증상이 안 났다**(종 PNG 96×96, 아이템 30×30). 왜곡은 캔버스가 종마다 크롭된 **Gen-V 움직이는 GIF**
  에서만 드러났다(잭키 #325 는 36×66 → 가로 1.83배 뚱뚱, 피카츄 #25 50×46, 팬텀 #143 74×75). 즉 정적
  경로만 검증한 테스트는 통과하면서 GIF 경로를 통째로 비워 둔다. 규율은 셋이다:
  ① 원본 비율은 한 곳(`SpriteFit.size`)에서만 계산하고 **모든 렌더 경로가 그걸 공유한다** — SwiftUI
  (`SpriteView`·`ItemIconView`)든 AppKit `draw(in:)`(메뉴바 `menuBarLayout`)든.
  ② **바깥 슬롯은 정사각으로 유지하고 안쪽 이미지만 줄인다** — 진화 라인·도감 그리드의 폭 계산
  (`EvoLineView.rowWidth`)이 칸을 정사각으로 전제하므로 바깥을 건드리면 레이아웃이 흔들린다.
  (메뉴바는 예외: 세로 22 고정 + 가로는 맞춘 폭 — 정사각 고정이면 세로로 긴 종 좌우에 죽은 여백이 생겨
  사용량 숫자와 벌어진다.)
  ③ **크기가 0 인 원본**(디코드 실패)은 0 나눗셈이 되므로 정사각 폴백으로 막는다.
  회귀 가드(`SpriteAspectRatioTests`)는 실제 PokeAPI 캔버스 치수를 넣고, **"비정사각이 정사각으로 나오지
  않는다"는 트리거 명제를 따로 둔다** — 이게 없으면 원본이 애초에 정사각인 케이스로도 전부 통과한다.
- **In a fixed-height slot, fit the height, not a square.** The menu bar still fitted a 20pt
  square after the fix above, so a wide canvas was sized by its width: Swanna #581 (137×69) came out
  10pt tall, Tynamo #602 (57×19) under 7pt, and 345 of the 649 species missed the full 20pt height.
  The tests missed it because their widest fixture was Pikachu (50×46), where width and height
  barely differ, and the wide case asserted the square rule ("fills the 20pt content box" on the
  width). `menuBarLayout` now fits 20pt tall up to `menuBarSpriteMaxWidth` (36pt, 645/649 at full
  height). Measure a new cap against every canvas in the dex, not the cached few; the guard is
  `testWideSpriteFillsMenuBarHeightUntilTheWidthCap` with the real Swanna and Tynamo canvases.

- **물속의 알이 물 위에 둥둥 떠 보였고, 장면이 멈춰 있으면 물에서 나오지도 않았다.** 헤엄 표현(#83)은 몸 윗부분 45%만
  또렷하게 두고 아랫부분을 물빛 유령으로 그린다 — 알에 그대로 쓰니 부표처럼 떠 보였다(알은 헤엄치지 못한다). 5-whys:
  ① 알이 물에서 나오는 길(#80)은 `update` 의 `!canWalk` 분기에만 있어, 창이 가려져 장면이 멈추면(`isPaused`)
  알이 되든 몸통박치기로 빠지든(`pushMe` 의 멈춘 가지는 걸음만 끝내고 올라오지 않는다) 팀원 화면에선 계속 물속이다.
  ② 왜 못 걸렀나: #83 은 포켓몬 프레임으로만, #80 은 위치만 검증했다. 알의 물속 **모습**을 보는 테스트도 렌더도 없었고
  (#80 PR 이미지에 뜬 돔이 찍혀 있었는데도 아무도 짚지 않았다), 멈춘 장면 경로는 `pushMe` 에만 있고 `canWalk` 에는 없었다.
  수정: `eggSunk`(알+헤엄 높이)면 몸통을 투명(`alpha 0`, `isHidden` 은 "그림 있음" 표시라 건드리지 않는다)으로 하고
  그림 전체를 제자리에서 `submergedEggAlpha` 물빛 유령 하나로 그리며 고리는 알 꼭대기에 둔다(사진도 같다).
  멈춘 장면에서는 `canWalk=false` 와 `pushMe` 끝에서 `climbOutNowIfPaused` 가 같은 `stepAshore` 길로 바로 올라와 보고한다
  (빈 물가가 없으면 물에 남아 `update` 가 마저 하고, 걸음 수 상한으로 끝없이 돌지 않는다).
  **부류:** 상태별 모습(헤엄·잠수·춤·점프)은 **알 프레임으로도** 확인한다. `update` 에만 있는 로직은 장면이 멈추면 돌지
  않으므로, 내 위치·상태를 바꿔 팀원에게 가야 하는 것은 `pushMe` 처럼 멈춘 경로가 필요하다.
  **스윕:** 멈춘 장면에서 알이 물에 드는 길은 `canWalk` 전환과 `pushMe` 둘이고, 물에 든 채 **멈추기 시작하는** 경우
  (올라오는 도중 창이 가려짐)는 `isPaused` didSet 이 덮는다. 시작 칸은 물일 수 없다(`PlazaPreferences.lastTile` 이
  걸을 수 있는 칸만 받고 연못은 걸을 수 없다). `sit`/집중 자리는 땅이다. 연못 맨 윗줄에서는 잠긴 알이 연못 위 가장자리에
  잘리고 고리가 둑에 뜨므로 꼭대기를 가장자리까지 내려 앉힌다(사진도 같다). 잠긴 알은 점프로 뜨지 않는다(고리가 수면에 남는다).
  올라오는 길의 첫 물 칸을 팀원이 막으면 제자리에서 끝낸다(걸음이 안 나가면 중단 + 상한 64). 물에서 나오는 마지막 걸음은
  도착 칸이 땅이라 시작하자마자 서 있는 알로 그려진다 — 헤엄치다 나오는 포켓몬과 같고 **일부러 그렇다**. 상태별 모습 중
  알을 가정하지 못한 곳은 사진 렌더러의 `sink` 가지와 그림자·둥지 앞 테두리 숨김이었고 함께 고쳤다.
  가드: `testAnEggInTheWaterSinksWholeInPlace`, `testARemoteEggInTheWaterSinksTheSameWay`,
  `testASwimmingPokemonKeepsItsHeadAboveWater`, `testAnEggLeavingTheWaterStandsOnItsNestAgain`,
  `testAPhotoOfAnEggInTheWaterShowsItSunk`, `testAPausedSceneMovesAnEggAshoreAtOnceWhenIBecomeAnEgg`,
  `testAPausedPushIntoTheWaterLeavesAnEggOnTheShore`, `testAPausedEggWithNoFreeShoreWaitsInTheWater`, `testASunkEggInThePondsTopRowSinksDeeperInsteadOfBeingCut`,
  `testPhotoClipsASunkEggToThePondAndKeepsItWholeAtTheTopEdge`, `testAJumpingSunkEggStaysSunk`,
  `testAPlazaThatPausesWithMyEggStillInTheWaterClimbsItOut`, `testAPausedEggWhoseRouteIsBlockedByASwimmerStaysAndDoesNotHang`.

- **렌더 하니스의 가짜 시각(시간대)은 고정한다.** 하니스 시계를 `Calendar.current` 로 만들면 같은 "6월 15일 12시"가 KST Mac 과 UTC 러너에서 다른 순간이 되어, 순간에서 정해지는 아이템 스케줄이 달라져
  낮 장면에 노드가 하나 더 생겼다(스테이지 6 작업 4 에서 발견). **왜 못 걸렀나:** 렌더 비교는 같은 기계 두 커밋만 비교했고, 두 OS 를 비교한 적이 없었다(같은 기계에서는 시간대가 같다).
  **고침:** `PlazaFixtureTime` 이 고정 오프셋(+09:00, DST 없음, 시간대 DB 불필요)을 실행 동안 `NSTimeZone.default` 로 걸고 `Calendar.current` 가 따라오는지 `precondition` 으로 확인한다(KST Mac 의 렌더는 그대로).
  **규칙:** 시각을 쓰는 하니스는 시간대를 명시적으로 고정한다; 두 OS 렌더 비교(`scripts/plaza-render-cross.sh`, 윈도 `render` 잡)가 트리를 줄 단위로 비교하므로 순간이 어긋나면 노드 수 차이로 바로 드러난다.
- **Direct2D `DrawImage(..., SOURCE_COPY)` 는 `imageRect` 가 아니라 이미지 전체 경계를 덮어쓴다 — 영역에 쓰는 복사는 클립으로 가둔다.** 불꽃놀이 장면 60프레임(`fireworks-*@60`)에서 프레임 맨 아래 64 디바이스 행이
  투명 검정으로 나왔다(Mac 은 지도). 원인: 곱하기 효과(`scene_device.cpp` `drawEffect`)가 결과를 `SOURCE_COPY` 로 프레임에 그리는데, 효과 이미지는 프레임 크기 스크래치 비트맵이라
  `region`(스프라이트 자기 픽셀, 불꽃 빛은 0..896행) 밖의 행(896..959)까지 투명 검정으로 교체됐다. 진단: CI 에서 빛 명령의 `region=(-344,-384,1416,896)` 과 완전 투명 행 `896...959` 가 정확히 맞물림.
  **왜 못 걸렀나:** 일광·모닥불 곱하기 스프라이트는 프레임 전체를 덮어 영역 밖이 없었고, 작업별 골든은 스프라이트 안쪽 셀만 비교했다. 영역이 프레임보다 작은 곱하기는 두 OS 하니스가 처음 밟았다.
  **고침:** `copyRegion` 이 `PushAxisAlignedClip(region)` 안에서만 `SOURCE_COPY` 한다(두 곳: 색 곱하기·산술 합성). **부류 스윕:** `scene_device.cpp` 의 `DrawImage` 는 `SOURCE_OVER`(영향 없음)와 이 두 곳뿐,
  `window_surface.cpp` 의 프레임→백버퍼 복사는 전체 프레임 복사라 의도대로. **가드:** 하니스의 두 캡처(`knownRendererBugs` 에서 제거, 목록은 이제 비어 있고 목록 메커니즘은 대역 스템으로 단위 테스트),
  `testAMultiplySpriteThatEndsInsideTheFrameLeavesTheRestAlone`. **규칙:** 목록에 있는 캡처가 통과하면 테스트가 실패해 목록이 썩지 않는다.

## 프로세스 제어·업데이트

- **"나중에"는 이 버전을 다시 안 보여 주는 스킵이지, 다음에 또 물어보기가 아니다.** `skipCurrent()` 가
  `skippedUpdateVersion` 에 한 번 쓰면 `check()` 는 그 태그를 `available` 에서 빼고, Settings 의
  `else` 는 `available == nil` 을 "최신"으로 읽는다. 배너를 숨기는 것과 최신임을 선언하는 것은 다른
  상태다. 스킵한 릴리스는 `skipped` 로 남기고 Settings 는 "건너뜀" + 업데이트/다시 알리기를 보여 준다.
  더 새 태그는 배너로 돌아온다. 회귀: `testSkippedReleaseStaysVisibleAndANewerOneReturnsToTheBanner`,
  `testShowAgainRestoresTheBannerAndUpdateUsesTheSkippedRelease`.

- **쿨다운 스탬프는 *검증까지 통과한* 조회에만 찍는다.** `UpdateChecker.check` 가 GitHub 호출 *전에*
  `lastChecked` 를 쓰면 네트워크·파싱 실패도 30분 쿨다운을 시작해, 팝오버를 다시 열어도(`minInterval`
  디바운스) 재시도가 막히고 배너가 조용히 안 뜬다. "응답을 받았다"도 성공이 아니다 — 태그가 `MAJOR.MINOR.PATCH`
  가 아니면(`v2.6.0-beta.1`·`latest`·`v2.5`) `isNewer` 가 숫자 아닌 부분을 0 으로 읽어 prerelease 가 정식과
  같게, 쓰레기가 `0.0.0` 으로 비교된다. 실패·불안전 URL·지원하지 않는 태그는 스탬프하지 않고, 정규화
  (`normalizedReleaseVersion`)까지 통과한 릴리스만 스탬프한다. 조기 스탬프가 없어지면 겹친 `check()` 가
  동시에 나갈 수 있으므로 in-flight 가드도 둔다. 회귀(세 가드 각각 결함 주입으로 실패 확인):
  `testFailedCheckDoesNotStartTheCooldown`, `testRejectedReleaseUrlDoesNotStartTheCooldown`,
  `testMalformedOrPrereleaseTagIsAFailedCheckAndDoesNotBlockTheNextOne`, `testOverlappingChecksShareOneFetch`.

- **`pgrep -x <name>` 은 실행 파일의 정체성 검사이지, 기다리는 특정 프로세스에 대한 검사가 아니다.**
  중복 인스턴스가 떠 있는 동안 실행될 수 있는 모든 wait-for-exit 루프는 PID를 받아야 한다. `UpdateChecker`가
  자동 업데이트 시 앱 종료를 기다릴 때 `pgrep -x PokeTokenBar`를 쓰면, 중복 인스턴스가 살아있는 동안 루프를
  결코 빠져나오지 못하고 20초 타임아웃을 온전히 소모한다(#175). `ProcessInfo.processInfo.processIdentifier`로
  종료 대상 프로세스 PID를 전달하고 `kill -0 "$3"`로 특정 프로세스의 종료를 대기한다.

- **An empty SwiftUI `Settings` scene is still a real window.** The menu bar app registered
  `Settings { EmptyView() }` solely to satisfy its SwiftUI `App` entry point, although actual
  settings are hosted inside `PopoverView`. This leaves an unnecessary standalone Settings
  window available to framework launch/reopen behavior; the declaration predates the reported
  update. Keep the SwiftUI `App` and delegate adapter, and use `_EmptyScene()` instead of
  registering a window. The public underscored empty scene is present in macOS 14's SwiftUI;
  a bare empty `SceneBuilder` body does not compile with the macOS 14.5 SDK. Existing navigation
  tests only exercised
  the popover's settings flag and missed the separate framework-owned scene. Compare actual
  SwiftUI cold launch and status-item popover placement: changing startup to manual AppKit
  introduced clipped first-show geometry and was removed rather than adding placement code.

- **OCR output is an interpretation of rendered pixels.** `ZeroUsageHomeRenderingTests`
  failed on CI because Vision ranked `이번 달 일벌` before the correct `이번 달 일별`
  at the same maximum confidence. The saved fixture visibly contained the correct caption
  and chart; fixed-2× capture and lexical hints did not change the candidate ordering.
  Match the exact localized chart caption within one candidate from one observation's
  maximum-confidence tie, identically in both history states. Do not combine candidates,
  accept lower-confidence alternatives, or seed recognition with the expected vocabulary.
  Period summaries retain their top-1 text assertions. Hiding `MonthDailyTrend` must still
  fail the historical-chart assertion. Keep explicit pixel density, candidate diagnostics,
  and both CI fixture PNGs so recognition failures can be checked against rendered pixels.
  Other OCR harnesses passed the same CI runs; this repair is limited to the failing fixture.

- **A native coordinate test must hit the requested glyphs and await the whole transition.**
  CI run `41867694174` failed only the new region-chip test: Kanto's Maple card remained
  visible after one Johto click, although the local full gate passed. The test clicked the
  midpoint of Vision's whole observation and bypassed the existing navigation helper's
  bounded transition retry. Vision can combine adjacent chip labels into one observation,
  and native SwiftUI hit testing can lag the first rendered pixels. The original test saved
  neither click bounds nor pixels, so the CI log could not distinguish those two paths.
  Resolve the label's substring range against the same `VNRecognizedText` candidate and use
  its glyph bounds; do not fall back to the merged row's midpoint. Check the complete target
  state from one OCR snapshot before and after each bounded attempt, stopping immediately
  on success so a late first click is not blindly toggled back off. The class sweep found
  existing Back-navigation transitions already used a bounded retry; keep this repair on
  the new region interaction. Preserve exact both-visible → Johto-only → both-visible checks,
  log selected candidates/bounds, and save before/filtered/restored/failure PNGs into CI's
  existing native-render artifact. `testClickBoundsFocusOnTheRequestedTextInsideAMergedObservation`
  fails when glyph bounds are replaced by the full observation. The real CollectionView
  interaction must still fail if the production region selection is disconnected, even after
  all retry attempts. No production UI behavior or CI gate is changed for this harness repair.

- **Use unambiguous fixture words for exact OCR navigation assertions.**
  `DexBackNavigationTests.testBackFromDetailReturnsTheLogToWhereItWas` failed in CI run
  `39184274574`: after Back, Vision read the artificial oldest-catch label `Mon1` as
  `Mont`/`Monl` even though the rendered log had reached its bottom rows. Retrying the same
  pixels could not recover a candidate that was absent. A subsequent successful feature-branch
  run used `Oldest`, but that fixture repair had not reached `main`. Name only the first catch
  `Oldest` and keep the exact OCR match, rendered-row click, Back round trip, and segment-switch
  reset assertions. The production `CollectionView` and OCR candidate acceptance stay unchanged.
  This keeps the guard focused on restoring the viewed catch row rather than reading an
  ambiguous digit in a synthetic name.

- **A wider navigation label must not squeeze numeric period summaries.** Adding the localized
  recap capsule to the home's fixed-width summary row left too little space for its week/month
  labels and costs: the real English and German popovers split `$31.64` and `$121.30` across
  lines. The existing production render used Korean with costs disabled, so it never exercised
  that combination. Preserve the period totals' intrinsic width and let `ViewThatFits` move
  the recap button to a trailing row when the inline arrangement does not fit. If the two period
  groups alone exceed the content width (German `Nicht verfügbar`), stack those groups too;
  forcing their combined intrinsic width expands and clips the entire popover. The sibling
  Claude account period row has no recap control and does not share this trigger.
  `testRecapLabelKeepsPeriodCostsOnOneLine` renders the full production popover in English
  and German with costs enabled and requires each complete amount in one top-ranked OCR
  observation. Restoring the previous inline row makes both languages fail; joining OCR
  observations would conceal the broken digits. `testUnavailablePeriodCostsKeepGermanHomeWithinPopover`
  also requires the full leading home captions and both unavailable labels, so a clipped
  popover cannot pass merely because its trailing recap button remains visible.
  Match OCR recognition languages to each fixture: inheriting Korean for English made CI
  read `This` as `Thls` despite correct pixels. The period-cost fixtures retain strict labels
  and complete amounts; the original Korean quiet-day fixtures own the strict chart assertion.
  On the same CI image, English-only recognition corrected the period label but still read
  the unrelated chart caption `Daily` as `Dally`; do not teach OCR that misspelling or relax
  the original chart guard to make a period-row regression pass.

- **Nearest filter plus a centre-anchored node of odd device-pixel width puts the left edge on a half
  pixel.** The plaza snapped only the centre of the character sprite and the name plate. With an odd
  width in device pixels the left edge lands on .5 and the nearest filter drops or doubles columns:
  a 41-column plate drawn 1:1 kept only 33 distinct columns, and a 31-column sprite drawn at 3x came
  out 2, 3 or 4 px wide depending on x, so it shimmered while walking. It affects 1x displays and
  Retina zoom 1 and 3; Retina zoom 2 is the only clean case, which is why it passed on the
  developer's screen. The camera had the same shape: `layout()` re-snapped `rect.midX` and undid the
  origin snap `PlazaCamera.visibleRect` had already done. Snap the left (and bottom) edge, then add
  half the size back (`PlazaPixelSnap`), and never re-snap a value derived from an already snapped
  origin. `layout()` falls back to backing 2 without a window, so tests cannot reach the 1x branch;
  the pure helper takes `backing` and `zoom` and `PlazaPixelSnapTests` assert the edge lands on the
  device grid for 1x zoom 2, odd plate width, odd viewport and Retina zoom 1 and 3. Injecting the
  centre-only snap makes them fail. Class sweep: the only other `.nearest` use is the menu-bar
  sprite `CALayer` in `PokeTokenBarApp.swift` (default centre anchor, `resizeAspect`); it was not
  changed and was not measured.

- **A system memory-pressure signal stops `NSCache` for the whole process, so tests that read back what
  they just cached fail in a block on some runs.** The full suite failed with exactly 85 assertions
  (`SpriteImageCacheTests` 25, `UnownSpriteCacheTests` 52, `UnownSpriteViewTests` 4,
  `SpriteAnimationPreviewTests` 4), then passed on the next run of the same code. libcache keeps a pressure
  state until the next normal signal: after warn, caches without a limit keep nothing; after critical,
  caches that already exist keep nothing, even with a `countLimit`. A fresh cache with a limit still works,
  so a quick check in a new cache looks healthy. Calling libcache's `cache_simulate_memory_warning_event(4)`
  in the test process reproduces the same 85 failures with the same per-suite counts. In the real failure
  the Mac entered warn at 17:25:45, apps were being suspended at 17:25:54 as the failures began, and it
  returned to normal at 17:27:05. No log line said "critical", so that level is inferred from the matching
  failure pattern. **Why it was misread:** a bisect pointed at `PlazaTileArtTests` and two clean runs after
  making that test lighter looked like proof. The failure is intermittent, so those passes proved nothing,
  and the real cause was found only by logging who evicted and probing a fresh cache at several points in
  the run. Do not treat clean runs as evidence for a fix to an intermittent failure; reproduce the exact
  failure on demand first. **Production:** nothing to fix. A miss reloads from disk, and all three
  production caches have a limit. **Fix:** `AaaNSCachePressureGuardTests` registers a test observer that
  sends a normal signal before every test, with no change to the upstream test files, and its name makes it
  run first. Disabling the observer brings back all 85 failures under a simulated critical signal. A signal
  that arrives in the middle of a test can still fail that test. A filtered run that leaves this class out
  has no guard.

- **`${VAR//\/\//\/}` keeps the backslash in macOS's bash 3.2, so a path can gain a stray `\`.**
  `scripts/plaza-dev.sh` built `${TMPDIR}/ptb-plaza-dev`, where `TMPDIR` already ends in `/`, then collapsed
  `//` with that substitution. Bash 3.2 writes the escaped replacement literally, so the state folder became
  `…/T\/ptb-plaza-dev`. **Why nothing caught it:** `mkdir -p` makes any path work, the app ran normally from
  that folder, and nobody read the resulting path. It surfaced only when a listing of the expected folder
  came back empty. **Fix:** strip the trailing slash with `${DEV_DIR%/}`. No other script uses this
  substitution. The team settings suite name is a hash of the state path, so moving a state folder orphans
  its team settings; the existing dev settings were copied to the new suite by hand. There is no automated
  test because this is a dev script. It was checked on `/bin/bash` 3.2 with `TMPDIR` ending in a slash,
  without one and unset, and by reading `PTB_STATE_DIR` from the running app.

- **A Swift `String.count` is not a size bound: one grapheme cluster can be any number of bytes and any width.**
  `TeamSettings.validNickname` accepted "1 to 12 Characters". A zero-width-joiner emoji chain of any length is
  one Character, so a 1,000-emoji nickname passed, was broadcast to the team, and `PlazaNamePlate.image` sized
  a 42,062 px bitmap from it. SpriteKit asks Metal for a texture of that width and Metal aborts the process above
  32,768 px, so one teammate could close the app of everyone with the plaza open. **Why nothing caught it:** the
  validator tests used Korean and emoji strings where one Character is a few bytes, and the plate tests used
  short names, so no test ever put a long Character through either. **Fix:** `validNickname` also requires
  `utf8.count <= 320`, and `PlazaNamePlate.image` truncates to `maxPixelWidth` (2,048 px) with
  `CTLineCreateTruncatedLine` and returns nil instead of force unwrapping CoreGraphics results. Tests build a
  1,000-link chain (asserting it is one Character) for both. **Class sweep:** a count of Characters used as a
  limit on text that arrives from outside; the other one was the comment length in `TeamFeedStore.insert`, which
  goes away because inbound comments are rejected outright. New limits on untrusted text bound bytes (`utf8.count`),
  and anything that draws it bounds its own output size.

- **Pruning a set relative to its own largest value lets one far value evict the one you just added.**
  `PlazaWindowController.learnTaken` kept the eight taken item slots below the largest it knew. A teammate whose
  clock ran a day or more ahead passed on a slot eight or more past mine, so the slot I had just picked up was
  dropped in the same call. The item stayed on the map, and since I was still standing on it, every frame picked
  it up again: one item in the bag, one emote and one save per frame. The far slot was saved and relayed by every
  Mac, so it spread to the whole team and survived restarts until real time caught up. A modified client sending
  `Int.min` also trapped on `latest - 8`. **Why nothing caught it:** the pruning test fed slots in rising order,
  so the slot just learned was always the largest; no test learned a slot below one already known. **Fix:** keep
  only slots in a window around my own clock (the last eight up to now, plus the next one for small clock skew),
  both when learning and when loading saved slots. Tests cover a far slot from a teammate's presence (granted once,
  not saved, not relayed), a far slot saved earlier, and the Int extremes. **Class sweep:** other places that keep
  or trim values from teammates. `TeamFeedStore` already admits events and reactions only inside a window around
  its own clock (`inWindow`) before trimming by count, and reports an entry trimmed right away as not new. The
  plaza chat log trims by count in arrival order, and emote throttles compare times from the controller's own
  clock. None of them trims by a value a teammate chose.

- **A save throttle that lets the first save through can still hold back the expensive one.**
  #49 made `LocalUsageCache` save at most every 30 minutes, with the first save at once. On a cold start (first
  install, a parser version bump, an unreadable snapshot) that first save holds only the today window from phase 1.
  Phase 2 parses a month of files, which takes tens of seconds, and that waited 30 minutes, so quitting or updating
  in that window parsed everything again on the next launch. **Why nothing caught it:** the rewrite budget test models
  a steady day with one growing file, and no test went through a cold start's two phases with the throttle on.
  **Fix:** save at once when 200 files never seen before have been parsed since the last save
  (`freshFilesForImmediateSave`). Normal days create about 180 new session files, a few per 30 minutes. The budget
  test now adds a new session file every 8 minutes and still allows at most 49 rewrites a day, and a new test
  checks that a relaunch after phase 2 reads the month from the snapshot. **Class sweep:** no other save in
  `Sources` is throttled.

- **`SKView.isPaused = false` does not guarantee that SpriteKit's frames come back.**
  After switching to another app and back, the plaza froze: teammates' chat still arrived, nobody moved, and closing
  and reopening the window recovered it. The state lines from #50/#54 caught it in v2.5.613. After `rendering
  visible=true` the view and the scene were both unpaused and the window was visible and key, yet `updates` stayed at
  9856 for 67 seconds. A later hide and show of the window brought it back. The same resume had worked two minutes
  earlier. The disassembly of SpriteKit on this Mac explains it. `-[SKView setPaused:]` returns early when the value
  is unchanged, and otherwise starts or stops its `SKDisplayLink`, which starts or stops a CVDisplayLink through
  blocks on another queue. Each vsync is dropped while a callback is in flight, and the link rebuilds itself when
  its frame rate looks wrong, so the start sometimes leaves the signal off. Setting `false` again then does nothing,
  and only another pause and resume restarts it. **Why nothing caught it:** the tests drive a fake render loop and
  check our pause flags, not that SpriteKit calls `update` again. The live experiments (cover, minimize, hide,
  quick toggles) never hit the intermittent race. The first logs recorded the update count only at state changes,
  so the stall was invisible until a resume left it unchanged. **Fix:** a watchdog in `PlazaWindowController` looks
  once a second while rendering is on (view and scene unpaused, no live resize). If `update` has not run since the
  last look, it pauses and resumes the view and logs `render loop stalled, kick N` (the first three and every 60th),
  then `render loop resumed after N kick(s)`. Tests cover the wake-up, a paused plaza left alone, the log cap and
  the timer stopping on close. Whether one pause and resume always restarts a stuck view is so far shown only by the
  natural recovery; the log lines will show it in the field. **Class sweep:** the plaza `SKView` is the only
  SpriteKit view. The roster's bounce is a SwiftUI value with no display link of its own.

- **A feature that needs a moment beside a character is dead when another rule fires the instant you arrive.**
  In v2.5.625 the plaza Ditto could be bounced away with a tackle and danced with, yet in real use it only ever
  transformed and turned back. A Ditto that is not resting copied a teammate the moment they stood beside it and
  fled, so the tackle always landed on the copy (which reveals it) and there was nobody left to dance with. The
  bounce was reachable only during the three-minute rest, and dancing along only from a diagonal tile, during the
  rest, or with a copy. **Why nothing caught it:** every controller test for the tackle and the dance started
  from `dittoForm(...).turnedBack(now:)`, a resting Ditto, because that is the state in which the Ditto holds still.
  No test walked up to a fresh one, which is what a person does first. **Fix:** the Ditto copies a neighbour only
  after they stood beside it for `PlazaDittoBrain.copyDelay` (3 s at first, 2 s since the next change), waits for them meanwhile, and copies nobody
  while it dances along. Tests start from a fresh Ditto and tackle or dance inside the delay. **Class sweep:** the
  other things done to a character beside you (greeting, tackle, pull-under, startle, the member menu) target
  teammates, who do not react to adjacency. The Ditto copy's own prank walks up and tackles at once by design.
  **When adding an action on a character:** test it from the state a person meets first, not only the state that is
  easiest to hold still.

- **테스트가 흘린 UserDefaults 스위트가 cfprefsd 를 막으면 모든 앱의 설정이 "사라진다".**
  증상: 앱이 빈 UserDefaults 로 떠서 `team.enabled` 가 false 가 되고 팀 광장과 지도 아이콘이 사라졌으며, 앱이 진짜 값을
  기본값으로 덮어썼다. 시스템 데몬의 설정 접근도 함께 실패했다. 원인: 테스트가 테스트마다 UUID 이름 스위트
  (`ptb.test.team.runtime.<UUID>`, `plaza.ditto.prefs.<UUID>` …)를 만들었고, `removePersistentDomain` 은 도메인을
  비울 뿐 `~/Library/Preferences/<suite>.plist` 를 남긴다 — 게다가 cfprefsd 는 변경 뒤 몇 초 늦게 파일을 쓰므로
  지운 직후에도 다시 생긴다. 결국 그 폴더에 34만 개 항목이 쌓였고(그중 341.7k 가 테스트 스위트) 사용자의 cfprefsd 에이전트가
  디렉터리 fd 508 개를 쥔 채 모든 프로세스의 읽기("Unable to determine access")와 쓰기("Path not accessible")를 거절했다.
  정상이면 DIR fd 는 1 개 안팎이다. 오독: `defaults read` 가 어디서나 실패해서 "에이전트 셸에서 띄운 앱만 설정에
  못 닿는다"로 잘못 결론 내렸고(#108, 철회), 스크립트에 "직접 열어라" 안내를 넣었다. 실패 범위가 에이전트 셸에 한정되는지
  확인하지 않았다. 진단: `lsof -p $(pgrep -u $USER -x cfprefsd) | awk '$5=="DIR"' | wc -l` 이 수백이면 막힌 것이고,
  `log show --last 1h --predicate 'process == "cfprefsd" AND eventMessage CONTAINS "rejecting"'` 에 거절 기록이 남는다.
  복구: 앱 plist 를 백업하고, 앱을 종료하고, cfprefsd 에이전트를 kill 해 launchd 가 새로 띄우게 한 뒤(fd 1 개로 돌아온다),
  덮어써진 키를 백업에서 고치고, 앱을 다시 연다. 먼저 앱을 끄지 않으면 앱이 다시 덮어쓴다.
  **규칙:** 테스트는 스위트를 `TestDefaults.make(suite:)` 로만 만든다 — 이 헬퍼가 번들 종료 때 plist 를 지우고 cfprefsd 의
  지연 쓰기까지 기다려 다시 지운다. `Tests/` 에서 `TestDefaultsScanTests` 가 헬퍼 밖의 직접 생성 호출을 실패시킨다.
  테스트에서 `removePersistentDomain` 을 따로 부르지 않는다(그 호출이 빈 plist 를 다시 만든다). 5-whys 공백: 각 테스트는
  자기 스위트를 지웠다고 믿어 통과했고, 흘린 파일은 테스트 밖(`~/Library/Preferences`)에만 쌓여 어떤 게이트도 보지 않았다.
  **재발 (2026-11-13, v2.5.630 게이트).** #110 이후에도 전체 스위트(3623 개)를 돌리자 파일은 2 개만 남았는데 cfprefsd 가
  디렉터리 fd 507 개를 쥐고 있었고, 앱이 팀 리스너 없이 떴다(cfprefsd 재시작으로 복구). 측정한 메커니즘: cfprefsd 의 **디렉터리 fd 수는
  테스트 프로세스가 새로 만든 plist 가 늘면 같이 오르고, 그 파일을 지우면 내려간다**(스위트 50 개를 만들고 종료하면 1 → 51, 파일 50 개를 지우면 1 초 안에 1). 107 개
  테스트 슬라이스에서 plist 216 개가 동시에 존재했고 fd 가 108 까지 올랐다(테스트 하나가 가장 많이 연 건 `PlazaEmoteTests` 의
  `testHeartAtAwayMemberTargetsThem` 으로 약 103 개 — 후보 팀원을 만들 때마다 suite 를 하나씩 열었다). #110 은 번들 종료 때 지우기만 해서, 실행 중
  동시에 존재하는 plist 수(= 테스트 수에 비례)가 한도를 넘는 것은 막지 못했고, 한도를 넘어 막힌 cfprefsd 는 나중에 파일을
  지워도 풀리지 않는다. 5-whys 공백: #110 은 끝 상태(남은 파일 없음)만 봤고 `TestDefaultsScanTests` 는 "헬퍼를 거치는가"만
  봤다 — 실행 중 동시 plist 수를 재는 것은 없었다. **고침:** `TestDefaults` 가 UUID 스위트 대신 `ptb.test.pool.<pid>.<n>` 풀(pid 는 동시에 도는 `swift test` 끼리 도메인을 공유하지 않게 한다)을
  재사용한다. 한 테스트 케이스(`testCaseWillStart`~`DidFinish`) 안에서 요청 이름마다 풀 슬롯 하나, 같은 이름은 같은
  `UserDefaults` 객체이고, 슬롯은 내줄 때와 테스트 끝에 비운다. 풀은 한 테스트가 요청하는 서로 다른 이름의 최대 개수까지만
  자란다(Plaza|Team 1727 개 테스트에서 fd 피크 22, 32 개 상한을 두기 전에는 84). 테스트 밖 요청은 8 슬롯 라운드로빈이다. 한 테스트가 서로 다른 이름을 **32 개** 넘게 열면 `XCTFail` 한다(그래도 쓸 수 있는 저장소는 돌려줘 실행은 이어진다) — 이름을 재사용할 것. 번들 종료 때 이 프로세스의 풀 plist 전부(`ptb.test.pool*.<pid>.*`)를 지우고, 첫 요청 때 죽은 pid 의 잔여 풀 plist 도 지운다. `TestDefaultsScanTests` 는 헬퍼 밖의 `removePersistentDomain(` 과 풀 테스트 밖의 `TestDefaults(prefix:` 도 막는다. `TestDefaultsPoolTests` 가
  동시 도메인 수 상한·재사용 슬롯 빈 상태·같은 이름 동일 객체를 고정한다(결함 주입으로 각각 실패 확인). **릴리스 안전망:**
  `scripts/cfprefsd-guard.sh` 가 `team-release.sh` 의 테스트 게이트 직후(앱 설치·실행 전) DIR fd 가 100 을 넘으면 경고하고
  `cfprefsd agent` 를 재시작해 내려갈 때까지 기다리며, 회복하지 않으면 릴리스를 중단한다.

  **재발 2 (2026-11-13, 풀의 늦은 쓰기).** 전체 게이트에서 `UsageLedgerRecordingTests.testTheFirstRefreshAlreadyFillsTheLedger` 가
  한 번 실패했다 — `UsageLedger.load(from: defaults)` 가 테스트 픽스처 이틀이 아니라 개발자 **실제** 원장(11 일, 수십억 토큰)을
  돌려줬고(`store.dailyLedger` 는 맞았다), 단독으로는 통과했다. 원인 둘의 합이다. ① `CustomScanRootsTests` 등은 `providers:` 없이
  `UsageStore(...)` 를 만들어 기본 프로바이더 = 실제 `~/.claude` 등 로그를 읽었고, `setCustomScanRoots` 같은 setter 는 기다리지 않는
  `Task { await refresh() }` 를 띄워 **테스트가 끝난 뒤** refresh 가 끝나며 `recordDailyLedger` 가 `defaults` 에 저장한다.
  ② #125 의 풀은 슬롯을 다음 테스트에 다시 내주므로 그 늦은 쓰기가 **방금 같은 슬롯을 받은 다음 테스트**의 도메인에 떨어진다
  (UUID 스위트 시절엔 아무도 다시 읽지 않는 도메인이었다). 결정적 재현: 느린 프로바이더를 단 스토어에서 setter 를 부르고 즉시 끝나는 테스트
  뒤에, 다음 테스트가 3 초 기다리며 같은 키를 읽는다(고치기 전 실패 확인). 5-whys 공백: #125 리뷰가 "다음 테스트로의 늦은 쓰기"를 minor 로
  짚었으나 재현 테스트가 없었고, 풀 테스트는 늦은 쓰기를 *슬롯이 다시 내줄 때 비워지는가*(핸드아웃 시점)로만 봤다 — 핸드아웃 **뒤**에
  떨어지는 쓰기는 어느 테스트도 밟지 않았다. **고침 (인프라):** 테스트가 받는 객체를 `PooledDefaults`(`UserDefaults` 서브클래스)로 하고,
  테스트가 끝날 때(또는 슬롯이 넘어갈 때) `close()` 해서 이후 `set`/`removeObject` 를 버린다. 물리 도메인은 그대로 풀이라
  cfprefsd 한도는 유지된다(Plaza|Team 1823 개에서 fd 피크 22). 시도하고 버린 안: 테스트마다 유일한 도메인 + 끝/경계마다 plist 삭제 —
  cfprefsd 가 삭제 뒤에도 최근 열린 도메인 fd 를 한동안 쥐어 Plaza|Team 에서 피크 315(>300)로 올랐다. 도메인 수가 아니라 **만들어지는
  도메인의 속도**에 비례하는 것으로 보인다(1 회 측정, 다른 세션의 빌드가 겹쳤다) — 빠른 슬라이스에서 한도를 넘을 수 있다. 주의: 서브클래스의 락은 재귀여야 한다 — `super.set(Int,…)` 가
  `set(_:forKey:)` 를 다시 불러 일반 락이면 교착한다. **고침 (원인):** `Tests/` 의 모든 `UsageStore(` 는 `providers:` 를 명시해야 한다 —
  `UsageStoreHermeticityScanTests` 가 어긴 호출을 실패시킨다(레지스트리 확인은 `UsageStore.defaultProviders()` 를 넘기고, 스스로 refresh 하는
  스토어는 `makeHermeticUsageStore` 로 프로바이더·한도·Claude 설정 폴더 탐색을 모두 막는다). **회귀 테스트:** `TestDefaultsLateWriteTests`
  (실제 `UsageStore` 의 늦은 저장이 다음 테스트에 안 보인다), `TestDefaultsPoolTests` 의 늦은 쓰기·외부 링 테스트 — `close()` 를 no-op 으로
  주입하면 실패, 스캔 테스트는 맨 `UsageStore(` 를 주입하면 실패함을 확인했다. **두 번째 늦은 쓰기 (리뷰에서 발견):** `UsageStore.reschedule` / `suspendPolling` 의 타이머 클로저가 `{ _ in Task { @MainActor [weak self] in … } }` 였다 — 안쪽 `[weak self]` 는 바깥 클로저의 캡처를 약하게 만들지 못해 바깥 클로저가 `self` 를 **강하게** 쥔다. 타이머가 런루프에 붙어 있으니 테스트가 만든 모든 스토어가 스코프가 끝나도 죽지 않고 120 s 마다 실제 로그를 읽어 풀 슬롯에 원장을 저장했다(보고된 11 일 원장과 더 잘 맞는다). 고침: `{ [weak self] _ in Task { @MainActor in await self?.refresh() } }`(앱 동작 동일 — 앱은 스토어를 평생 쥔다). 같은 패턴 스윕: `Sources/` 의 `Timer(` 4 곳(UsageStore 2 곳이 이 결함, `PokeTokenBarApp.swift:577`·`TeamTransport.swift:187` 은 바깥 클로저에 이미 `[weak self]`)과 NotificationCenter 옵저버(바깥 `[weak self]`) 는 정상. 회귀 테스트 `testAStoreIsReleasedWhenItsScopeEnds`(스코프 뒤 약참조가 nil) — 옛 캡처를 되돌리면 실패. **레지스트리 테스트:** `UsageStore(providers: defaultProviders())` 는 타이머를 통해 실제 로그·Keychain·네트워크를 만지므로 `UsageStore.defaultProviders().map(\.id)` 로 바꿔 스토어를 만들지 않는다(`registeredProviderIDs` 는 `providers.map(\.id)` 일 뿐이라 잃는 것 없음). 스캔은 `defaultProviders` 를 넘기는 `UsageStore(`/`UsageStore.init(` 도, 자기 인자 목록 밖(중첩 호출·문자열)의 `providers:` 도 실패시킨다. 남은 것: `LocalUsageParityTests` 는 `PTB_PARITY=1` 일 때만
  도는 의도적 실제 로그 대조라 `.standard` 를 쓴다(기본 스킵).

- **윈도우 프로세스 환경의 검색 경로 키는 `Path` 인데 코드는 `"PATH"` 만 읽고 썼다.** `BinaryLocator.augmentedEnvironment` 가 `base["PATH"]`(nil)를
  읽고 `env["PATH"]` 를 써서, 자식 프로세스 환경에 `Path` 와 `PATH` 가 둘 다 생겼다(어느 쪽이 이기는지 미정의). 도달 경로: Codex 한도 조회 등
  `augmentedEnvironment` 를 쓰는 모든 자식 프로세스. **왜 못 걸렀나:** `testAugmentedPathUsesThePlatformSeparator` 는 `["PATH": …]` 를 주입했다 —
  실제 윈도우 프로세스의 `Path` 키가 아니라 결함 트리거와 *다른 경로*로 통과했다. **고침:** `PlatformCompat.pathVariableKey(in:)`(윈도우: 이미 있는 키를 대소문자 무시로
  찾고 없으면 `Path`; 맥: `"PATH"`). **부류 스윕:** 공용 소스의 `["PATH"]`·`"PATH"` 사용처 전수 — `BinaryLocator` 외에 없다. 같은 부류로 `.cmd` 해석(`PATHEXT`,
  `executableCandidates`)과 앱 데이터 폴더(`userApplicationSupport(home:)`)도 PlatformCompat 로 모았다. **회귀 테스트:** `WindowsPathTests.testAugmentedEnvironmentKeepsOnePathKey`
  (`Path` 만 있는 기반 환경 → 키가 하나; 맥은 옛 출력 고정). `pathVariableKey` 가 `"PATH"` 를 돌려주게 주입해 윈도우 CI 에서 실패하는지 확인.
- **npm `.cmd` shim 은 cmd.exe 가 실행하므로 인자의 `& | < > ^ % !` 가 해석된다 (F19).** 오늘 shim 에 가는 인자는 Codex 의 `["app-server", "--stdio"]` 뿐이라 도달 가능한 결함은
  없다 — 런타임 가드는 두지 않고 규칙만 고정했다. **가드(기계):** `PlatformCompat.isBatchSafe` + `ToolLaunchArgumentTests`(문자 거부), `ToolLaunchArgumentScanTests`(공용 소스의
  `arguments: ["…"]` 리터럴이 전부 안전한 고정 문자열이고, `Process` 의 `.arguments =` 지점이 `BinaryLocator`·`ProcessRunner` 둘뿐임을 고정; 맥 전용). 규칙은 `provider-extension.md`.
- **위치를 확인하지 못한 도구 경로를 추측으로 채우지 않는다.** 윈도우 로그 루트·도구 디렉터리는 도구의 공개 문서·소스·문서화된 환경변수로 확인된 것만 넣고, 나머지는 비워 "데이터 없음"으로 둔다
  (Claude Desktop 세션 폴더가 그 예: `claudeDesktopSessionStores` 는 윈도우에서 `[]`).
- **병렬 브랜치가 각자 통과해도 합친 결과는 실패할 수 있다 — 맥 전용 스캔은 윈도우 CI 가 못 본다.** 도구 경로 작업이 넣은 `ToolLaunchArgumentScanTests`(실행 지점 허용 목록)와 앱 중심부 작업이
  넣은 `WindowsSelftest`(자기 실행 파일을 띄움)가 따로 통과한 뒤, 합쳐진 `windows-port` 의 전체 게이트에서 실패했다. 스캔이 `.arguments =` 문자열만 봐서 `self.arguments = arguments`(실행
  아님, `WindowsApp`)까지 잡은 것도 겹쳤다. **왜 못 걸렀나:** 속도 규칙상 작업별로 걸러 돌린 묶음에 상대 브랜치의 새 스캔이 없었고, 이 스캔은 맥 전용이라 윈도우 CI 도 돌리지 않는다.
  **고침:** 스캔이 `Process()` 와 `.arguments =` 가 함께 있는 파일만 실행 지점으로 보고, 자가 점검을 허용 목록에 넣었다(shim 이 아닌 자기 실행 파일, 인자는 스스로 만든 플래그).
  **규칙:** `windows-port` 로 합치기 전에 `swift test --filter 'ScanTests'` 를 합친 트리에서 돌린다(몇 초). 전체 게이트는 계속 중간 점검 지점에서만.

- **패널이 같은 값을 다시 쓰는 모델 변화에도 그려진다 / 테스트가 약하게 쥔 객체를 곧바로 놓는다 (Track A Task 15–16).** `@Observable` 은 값이 같아도 쓰기마다 알린다 — 컨트롤러가 창이 이미 보여 주는 값을
  다시 쓰면(열 때 `backgroundModel.isHidden = …`) 패널이 두 번 그려졌다(이름 색 패널 2회; "열 때 패널마다 한 번" 테스트가 잡았다). **고침:** 패널은 마지막으로 그린 상태와 다를 때만 `onChange` 를 부른다(`PlazaPillsPanel`
  과 같은 규칙, 이제 `PlazaChangeObserver` + `rendered` 로 모든 패널). 같은 부류 — HUD 는 호스트와 패널의 `onChange` 를 약하게 쥔다: 테스트가 `let (hud, _, …) = rig()` 처럼 호스트를 `_` 로 받으면 곧바로 사라져 이후
  렌더가 조용히 멈추고 단언이 엉뚱한 곳에서 깨진다(Task 14 에서도 한 번). 규칙: 약하게 쥐는 객체는 지역 변수로 붙든다. **영구 캡처:** `testControlsRenderOnlyWhenTheirContentChanges`, `testMinimapRendersOncePerMinuteAtMost`.

- **윈도우 모달 루프(트레이 메뉴 `TrackPopupMenu`, `MessageBoxW`, 창 이동·크기 조절 루프)가 열려 있는 동안 메인 큐가 멈춘다.** 모달 루프는 메인 스레드에서 자기 메시지 루프를
  돌며 창 메시지만 디스패치한다. 앱의 메인 루프(`RunLoop.main.run`)가 돌려 주던 `DispatchQueue.main`·`RunLoop` 타이머·`@MainActor` Task 는 메뉴가 닫힐 때까지 서 있다 —
  스토어 갱신 없음, 팀 링크가 생기면 하트비트도 없어 30 s 뒤 팀원이 이 멤버를 내린다. 맥은 메뉴가 열려 있어도 메인 큐를 계속 돌린다. **왜 못 걸렀나:** CI 자가 점검은 메뉴를 열 때
  메인 큐 일이 필요하지 않았다 — 메뉴 키 점검(`tray.menuKeys`)은 메뉴가 닫힌 뒤 갱신이 돌았는지만 보았다. 결함 트리거(메뉴가 *열려 있는 동안* 일이 도는가)를 밟는 점검이 없었다.
  **고침:** `WinModalPump`(`Platform/Windows/WinModalPump.swift`) — 모달 루프가 하나라도 활성인 동안만 싱크 창에 50 ms `SetTimer`, `WM_TIMER` 핸들러가 `RunLoop.main.run(mode: .default,
  before: Date())` 를 한 번 돈다(재진입 가드: 이미 틱 안이면 건너뜀). 마지막 `end` 에서 `KillTimer` — 모달 루프가 없을 때는 타이머도 깨움도 없다(유휴 비용 0). **규칙:** 새 모달 루프(대화상자,
  창 이동·크기, `MessageBoxW`)를 시작하는 코드는 호출 전 `WinModalPump.begin(_:)`, 호출 뒤 `defer { end(_:) }` 를 부른다. 이동·크기 루프는 싱크로 오는 `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` 가
  자동으로 begin/end 한다(다른 창은 같은 `WinSinkWindow` 라우팅이라 그대로). **회귀 점검:** `modalPump.*` 자가 점검(메뉴를 1.5 s 열어 둔 채 큐·타이머·Task 가 도는가, 재진입, 풍선, 타이머 수명, 메뉴 안에서
  `WindowsApp.exit`, 유휴) — 펌프를 끈 상태로 먼저 실행해 실패함을 확인했다.

- **"전/후" 비교의 *전* 쪽이 틀렸다 — `NSHostingView` + `cacheDisplay` 는 SwiftUI `.shadow(y:)` 를 위아래 뒤집어 그린다.** 같은 `Text.shadow(radius: 0, x: 1, y: 1)` 이 `ImageRenderer` 에서는 오른쪽 아래, 창 안
  호스팅 뷰 캡처에서는 오른쪽 *위*에 생긴다(1x 에서 확인, `testWhereSwiftUIPutsTheTextShadow`). 그림자 있는 글자가 많은 로스터·카드는 호스팅 캡처로 비교하면 글자마다 수백 픽셀이 틀려 보여 패널이 틀린 줄
  알게 된다(Task 17c–d 에서 한동안 그렇게 읽었다). **왜 못 걸렀나:** 17b 채팅 기록에는 그림자가 없어 호스팅 캡처가 맞았고, 그 방법을 그대로 물려받았다. **규칙:** `ScrollView` 가 없는 뷰는 `ImageRenderer`,
  있는 뷰는 `ImageRenderer` 그림에 스크롤 영역만 호스팅 캡처를 덧댄다(`ContentRig.renderedWithPatch`). 새 비교 방법을 쓸 때는 먼저 알려진 모양(그림자·둥근 모서리) 하나로 그 방법 자체를 확인한다.
  같은 부류: SwiftUI 느슨한 스택(`LazyVStack/LazyVGrid`)은 건너뛴 행을 어림잡은 높이로 쳐서, 한 번에 끝까지 스크롤하면 실제 끝을 지나 빈 칸이 보인다 — 비교는 100pt 씩 나눠 스크롤하고 패널이 갈 수 있는 끝까지만 간다.
  **두 번째 결함 (같은 항목, 2026-11-15): 펌프 틱이 메뉴의 키 입력을 가로챘다.** 틱이 부른 `RunLoop.main.run(mode:before:)` 는 CoreFoundation 의 Windows 루프라 입력이 있다고 나오면
  스스로 `PeekMessage(PM_REMOVE)` 로 메시지 하나를 꺼내 창에 디스패치한다 — 메뉴의 모달 루프가 막 읽으려던 키가 그 한 개였다면 메뉴는 그 키를 못 받는다(사용자 눈에는 "메뉴에서 키를 눌렀는데 가끔
  아무 일도 안 일어난다"; CI 의 `tray.menuKeys` 가 간헐 실패: Return 이 안 닿아 `action=none`). **왜 못 걸렀나:** 첫 수정의 점검은 키를 틱이 *돌지 않을 때* 보냈다 — 틱이 일을 하는 동안 큐에 키가
  있는 순간(수십 µs/50 ms)을 밟는 점검이 없었다. 처음 시도한 결정적 재현(30 ms 짜리 블록 안에서 키 전송)은 틱이 디스패치 포트 경로로 나가 `PeekMessage` 를 건너뛰어 0 건이라 틀린 가설이었다 —
  재현은 **6000 개 Down 키를 0.2–0.8 ms 무작위 간격으로 쏟아붓고, 싱크에 평범한 `WM_KEYDOWN` 으로 도착한 수**(메뉴 안의 키는 메뉴가 번역해 디스패치되지 않는다)를 세는 것이다: 옛 틱 13/6000 유실.
  시도하고 버린 안: ① CF 의 모드별 메시지 큐 마스크 SPI(`_CFRunLoopSetWindowsMessageQueueMask`)를 0 으로 — Foundation.dll 이 내보내지 않고 `CoreFoundation` 모듈도 임포트되지 않는다(러너에서 확인).
  ② 틱 직전 `GetQueueStatus` 로 입력이 없을 때만 — 검사와 CF 의 `PeekMessage` 사이 경합이 남는다(10–15/6000). **고침:** 틱이 (1) `_dispatch_main_queue_callback_4CF`(`dispatch.dll`)로 메인 큐·main-actor Task 를
  직접 비우고(메시지 큐 무관), (2) 런루프 패스 직전에 싱크로 미끼 `WM_NULL` 을 포스트한 뒤 큐의 첫 메시지가 그 미끼일 때만 패스를 돈다 — 포스트된 메시지는 포스트 순서로, 하드웨어 입력보다 먼저 나가므로
  CF 가 꺼내는 한 개는 미끼다; 앞에 다른 메시지가 있으면 그 틱을 건너뛴다(다음 틱은 50 ms 뒤). 결과: 6000 키 유실 0, `modalPump.*` 전부 통과, 유휴 불변. **규칙:** 모달 루프 안에서 일을 돌리는 코드는
  메시지 큐에서 아무것도 꺼내지 않아야 한다 — 입력 경합은 "가끔 한 개"라 통과가 증거가 아니므로 **유실 수를 세는 폭주 점검**(`modalPump.keysReachMenu`)으로 막는다.
  **세 번째 발견 (Stage 6 Task 5, 광장 창 끌기): 메인 큐 작업 *안에서* 모달 루프에 들어가면 펌프가 메인 큐를 못 비운다.** 자가 점검 `plaza.dragDraws` 가
  `@MainActor` Task(셀프테스트 본문) 안에서 `SendMessage(WM_SYSCOMMAND, SC_MOVE)` 로 이동 루프를 열었더니, 싱크의 `WM_TIMER` 펌프 틱은 루프 안에서 15–16 번
  돌았는데 그 사이 보낸 `DispatchQueue.main` 블록은 0/19 만 돌았다. main-actor 작업은 메인 디스패치 큐가 비우는 중에 실행되고, libdispatch 는 비우는 중에
  `_dispatch_main_queue_callback_4CF` 를 다시 불러도 큐를 다시 비우지 않는다(재진입 금지) — 펌프의 직접 비우기가 아무 일도 안 한다. 같은 루프를 *창 메시지로*
  (`PostMessage(SC_MOVE)`, 사용자의 끌기와 같은 경로) 열면 19/19, 18/19. **왜 헷갈렸나:** 첫 가설("광장의 60 Hz 틱 메시지가 `WM_TIMER` 를 굶긴다")로 우회
  코드를 넣었다가, 펌프 틱 수를 세는 진단을 붙이고서야 타이머가 정상으로 돈다는 것을 보았다 — 우회는 지웠다. **스윕:** 제품 코드에서 모달 루프에 들어가는 곳은
  트레이 메뉴(`WinTray` 콜백, 창 메시지) 하나라 안전하다. **규칙:** 모달 루프(대화상자·메시지 상자·메뉴·창 이동)는 창 메시지에서 연다. `Task`·`DispatchQueue.main`
  블록 안에서 열면 그동안 메인 큐 전체가 선다. 점검도 사용자와 같은 경로(포스트된 메시지)로 연다.
  **네 번째 (Stage 7 Task 3, 팝오버 키트):** 메뉴로도 같다 — `ui.kit.menuKeys` 의 첫 판(셀프테스트 Task 안에서 `TrackPopupMenu`)은 메인 큐 블록 0/10, 창 메시지로
  열면 10/10. 점검은 두 숫자를 다 찍는다(Task 안의 것은 정보용). 팝오버는 같은 훅 안에서 `IsDialogMessageW` 로 키를 나눠 주므로, **모달 루프가 도는 동안
  (`WinModalPump.depth > 0` 이거나 메뉴·이동 모드) 훅은 대화상자 경로를 건너뛴다** — 안 그러면 메뉴·스크롤 막대 끌기 루프가 읽을 키와 마우스를 훅이 먼저
  디스패치해 루프가 입력을 잃는다. 팝오버의 모달 루프(스크롤 막대 끌기 `WinScrollArea`, 이후 메뉴·대화상자)는 모두 `WinModalPump.begin/end` 안에서 돈다.
  **다섯 번째 (Stage 7 Task 3 사후 리뷰, 스크롤 막대 추적 루프가 마우스를 잃었다):** 네 번째의 가드는 "모달 루프의 입구를 하나씩 `begin/end` 로 감싸야"
  지켜지는 형태였는데, 감싼 입구는 뷰포트의 `WM_NCLBUTTONDOWN` 하나였다. 같은 `DefWindowProc` 추적 루프에 들어가는 다른 입구 — 스크롤 막대 화살표의
  두 번째 클릭(`WM_NCLBUTTONDBLCLK`, `CS_DBLCLKS` 가 없어도 비클라이언트에는 온다)과 여러 줄 입력칸 *자신의* 스크롤 막대(키트 서브클래스, 감싸지 않음) —
  에서는 `depth == 0` 이라 훅이 루프의 마우스(버튼 뗌)를 `IsDialogMessageW` 로 먼저 디스패치했고, 루프는 버튼 뗌을 못 받아 캡처를 쥔 채 계속 굴렀다.
  사용자 눈에는 "화살표를 두 번 눌렀더니 페이지가 끝까지 굴러가고 마우스가 붙잡힌다". 고치기 전 실행(run 43772318344): 화살표 더블클릭 → 오프셋 0 → 704
  (기대 32, 두 줄), 입력칸 화살표 한 번 → 첫 줄 0 → 9 (기대 +1), 둘 다 2 s 뒤에도 캡처를 쥐고 있어 감시자가 `WM_CANCELMODE` 로 풀었다.
  **왜 못 걸렀나:** 결함 주입 B 와 `ui.kit.scroll` 은 감싼 입구(썸 끌기, 첫 클릭)만 밟았다 — 같은 루프의 다른 입구를 밟는 점검이 없었다. 리뷰도 코드에서
  "감싼 곳"만 보고 루프가 어디서 시작될 수 있는지는 세지 않았다. **고침:** ① 훅은 마우스 메시지(0x0200–0x020E, 0x00A0–0x00AD)를 대화상자 경로로 보내지
  않는다 — `IsDialogMessageW` 가 마우스에 하는 일은 그냥 디스패치라 잃는 것이 없고, 앞으로 감싸지 않은 입구가 생겨도 루프의 마우스를 뺏지 않는다.
  ② 뷰포트와 키트 서브클래스가 `WM_NCLBUTTONDOWN`/`WM_NCLBUTTONDBLCLK` + `HTVSCROLL`/`HTHSCROLL` 을 `begin/end("scroll")` 로 감싸 루프 동안 메인 큐가 돈다.
  ③ 입력칸의 편집 메뉴(`WM_CONTEXTMENU` → `TrackPopupMenu`)도 감쌌다. **스윕 (비클라이언트·추적 루프 입구 전수):** 광장 창 — 이동·크기는 싱크의
  `WM_ENTERSIZEMOVE` 가 펌프를 열고 훅은 `GUI_INMOVESIZE` 로 비켜 남, 스크롤 막대 없음, 대화상자 창이 아님(훅 경로 밖). 콤보 드롭다운 목록 — 별도 팝업
  (`ComboLBox`, 대화상자의 자식이 아님)이라 대화상자 경로 밖, 목록 스크롤 막대를 누르는 동안 메인 큐가 서는 것은 이전과 같다(버튼을 쥔 동안만).
  트레이 메뉴 — `WinTray` 가 감쌈, 메뉴 모드. 슬라이더·버튼·입력칸 글자 끌기 — `SetCapture` 만 쓰고 자기 루프가 없음. **규칙:** 훅은 모달·추적 루프가 읽을
  입력을 가로채지 않는다(마우스는 아예, 키는 루프 중에). `DefWindowProc` 에 추적 루프를 맡기는 메시지(비클라이언트 버튼 다운·더블클릭, `WM_CONTEXTMENU`)는
  감싸고, 점검은 입구마다(첫 클릭, 더블클릭, 누른 채, 자식 컨트롤 자신의 막대) 밟는다. **회귀 점검:** `ui.kit.scrollClicks` — `SendInput` 으로 페이지 아래
  화살표 더블클릭(오프셋 정확히 두 줄), 입력칸 화살표 한 번(+1 줄), 각각 뒤에 캡처 없음·메인 큐 블록이 돈다; 입력칸 화살표와 페이지 화살표 더블클릭의 두 번째
  누름을 0.8 s 쥔 채 메인 큐 블록이 *쥔 동안* 돈다. `ui.kit.editMenu` — 입력칸 편집 메뉴가 열린 동안 메인 큐 블록. 결함 주입(감싸기만 제거, 훅의 마우스
  건너뛰기는 남김, `fault/w7-t3-scrollwrap` run 43775805367): 클릭은 더 이상 걸리지 않았다(오프셋 32, +1 줄, 캡처 없음 — 고치기 전 실행과의
  차이는 훅의 마우스 건너뛰기뿐이라 그 가드의 몫), 그러나 쥔 동안의 메인 큐 블록은 입력칸·페이지 모두 false 로 `ui.kit.scrollClicks` FAIL(감싸기의 몫).
  같은 실행에서 `ui.kit.editMenu` 의 첫 판은 감싸기 없이도 10/10 으로 통과했다 — 블록이 메뉴가 닫히기를 기다렸다가 닫힌 직후, 점검 스레드가 "열림"
  플래그를 내리기 전에 돌아 "열린 동안"으로 셌다. 점검이 결함과 다른 조건(플래그)으로 판정한 같은 부류다: 블록이 돌 때 메인 스레드의
  `GUI_POPUPMENUMODE` 를 스스로 읽게 고쳤다(재주입 결과는 Task 3 보고서 사후 리뷰 절).

- **맥 `CoreTextPlazaEngine.wrappedLines` 가 빈 줄을 "글 나머지 전부"로 바꿨다 — `CFRange` 길이 0 은 "끝까지"다.** `"a\n\nbcd"` 가 `a`, `bcd`, `bcd` 세 줄로 그려졌다(`bcd` 두 번). TextKit 이 빈 줄의 줄 조각을
  주면(끝의 공백·개행을 뗀 뒤 길이 0) 그 범위를 `CTTypesetterCreateLine(typesetter, CFRange(location:, length: 0))` 에 그대로 넘겼고, CoreText 는 길이 0 을 "location 부터 끝까지"로 읽는다.
  글이 개행으로 끝나는 경우도 같은 부류의 빠짐이었다: SwiftUI `Text` 는 끝 개행 뒤에 빈 줄 하나를 더 보이는데 TextKit 은 그것을 줄 조각이 아니라 `extraLineFragmentRect` 로만 알려서 줄이 하나 모자랐다.
  **닿는 입력:** 채팅은 `TeamChat.prepared` 가 개행을 공백으로 바꿔 닿지 않는다. 닉네임(`TeamSettings`)도 개행을 거절한다. 닿는 것은 피어가 보낸 `TeamEvent` 의 `speciesName`·`authorNickname`·
  반응 닉네임(길이만 제한, 개행은 거르지 않음) — 정상 클라이언트는 개행을 보내지 않으므로 악의적·이상한 피어에서만 보인다. 지워진 SwiftUI 뷰는 같은 글에서 빈 줄을 제대로 보였으므로 패널 전환이 만든
  회귀다(낮은 심각도). **왜 못 걸렀나:** 줄바꿈 말뭉치(`PlazaBreakCorpus`)에는 `"안녕\n두 번째 줄\n\n네 번째 줄"` 이 이미 있었지만 맥 쪽 골든은 TextKit/`CTFramesetter`(`paragraph` 경로)를
  재서 `wrappedLines` 의 타입세터 경로는 밟지 않았다 — 같은 글이 다른 코드 경로로 통과해 안심을 줬다. **고침:** 길이 0 범위는 빈 줄(`line("", font:)` / `line([])`)로, 글 끝 개행은 `extraLineFragmentRect`
  가 비어 있지 않을 때 빈 줄 하나를 더한다. 줄 수는 같은 글의 SwiftUI `Text` 높이/줄 높이와 맞춘다. **규칙:** `CFRange`/`NSRange` 의 길이 0 을 "빈 구간"으로 믿지 않는다 — CoreText 는 "끝까지"로 읽는다.
  **회귀 점검:** `PlazaBlankLineTests`(빈 줄, 연속·앞·끝 빈 줄, 색 조각 버전, SwiftUI `Text` 줄 수와 일치) — 고침을 빼고 실패함을 확인했다. 윈도 엔진은 이미 진짜 빈 줄을 만든다.

- **기본 상한은 그 값을 정한 호출부의 크기다 — API 응답용 32 MiB 본문 상한과 31.6 MiB 설치 파일 사이 여유가 1.3% 뿐이었다 (stage 8, 잠복).**
  윈도의 원샷 요청 이음매(`WinHTTPFetch.data`)는 본문을 `maxBodyBytes` 로 묶고, 기본값 `defaultMaxBodyBytes` 는 32 MiB 다. 그 값은
  "가장 큰 응답이 1 MB 미만"인 API 호출부를 보고 정했고(`WinHTTPFetch.swift` 39·63), `PlatformCompat.oneShotData` 가 그 기본값을 그대로
  물려준다. 앱 안 업데이트(stage 8 Task 6)가 이 이음매로 설치 파일을 받으면 상한을 따로 적지 않는 한 이 기본값을 받는다. 설치 파일은 stage 6
  Task 2 이후 31.6 MiB(2.5.634 CI 빌드 33,121,702 B, windows-app run 43736993382)이고 상한 33,554,432 B 와의 여유는 432,730 B(1.3%)다 — 글꼴이나
  그림 묶음 하나로 넘는다. 넘으면 `.dataLengthExceedsMaximum` → 다운로드 실패 → 릴리스 페이지가 열리고 로그 한 줄만 남아, 업데이트가 조용히
  죽는다. 계획 단계에서 찾았고(stage 8 계획 F13) 다운로드 코드가 아직 없어 사용자 영향은 없다.
  **왜 못 걸렀나:** ① 상한 테스트(`WindowsHTTPFetchTests`, 230 B gzip → 200,000 B)는 작은 `maxBodyBytes` 를 직접 넣어 "상한이 작동하는가"만
  봤고, 기본값과 실제로 가장 큰 페이로드의 관계는 아무것도 묶지 않았다. ② 설치 파일 크기는 워크플로 로그(`windows-app.yml` 의 바이트 출력)에만
  있고 Swift 상수와 이어진 곳이 없다. ③ 이음매 리뷰(status-burst 와 그 후속)는 그때의 호출부만 봤다 — 그들에게는 맞는 값이었지만 다음에 올
  호출부를 위한 값은 아니었다.
  **부류 스윕(고정 상한 ↔ 실제 크기):** `WinHTTPFetch.defaultMaxBodyBytes` 32 MiB ↔ 이음매의 모든 호출부(상태·한도·릴리스 JSON, PokeAPI
  REST·GraphQL, 이름표, 스프라이트·아이콘): 모두 1 MB 미만. `TeamWire.maxFrameBytes` 1 MiB ↔ 팀 프레임: 필드별 상한으로 이미 묶였다
  (§팀 네트워크 "저장하는 값을 재야 한다"). `SaveTransfer.maxFileBytes` 8 MiB, `PlazaGIFDecoder.maxOutputBytes` 256 MiB, `CPlazaD2D` 디코드
  512 MiB, `codexProbeByteLimit` 1 MiB(첫 줄만 찾는다), `AppLog.maxBytes` 2 MiB(회전이지 막지 않는다): 실제 크기 근처가 아니다. 이 작업의 새 상한
  `InstallerReleaseFeed.installerBytes`(1–200 MiB)는 실제의 6 배다. 실제 크기 근처의 고정 상한은 이음매 기본값 하나뿐이다.
  **가드(기계): Task 6 에서 닫힘.** ① 이음매 서명 — 다운로드는 `PlatformCompat.oneShotDownload(for:maxBytes:deadline:)` 하나뿐이고 `maxBytes`·
  `deadline` 에 기본값이 없다(WinHTTP 만 탄다: URLSession 으로 돌아가면 상한도 마감도 없으므로 그 경로는 실패로 끝난다). 호출부는
  `WindowsUpdateInstaller.install` 하나이고 상한으로 자산의 `installer.size` 를, 마감으로 15 분을 넘긴다 —
  `WindowsSeamScanTests.testTheUpdateDownloadAndItsCIHooksStayWhereTheyAre`(호출부 1곳·`installer.size` 전달·기본값 없음, 각 깨짐을 주입한
  `testTheUpdateSeamScanCatchesEachBreak`)와 `WindowsUpdateInstallerTests.testGoodBytesAreWrittenExactlyAndSetupGetsThatPathAndItsArguments`
  (주입한 다운로드가 받은 상한 == 크기, 마감 == 900 s). ② 트리거 브랜치 — 32 MiB + 1 B 본문이 *실제* WinHTTP 이음매를 러너의 루프백으로 지난다:
  `WindowsUpdateInstallerTests.testABodyOverTheSeamsDefaultCapPassesWithTheInstallersOwnCap`(같은 본문이 기본 상한으로는
  `.dataLengthExceedsMaximum`, 설치 파일 자신의 크기 상한으로는 통과해 디스크에 33,554,433 B), 출하 바이너리 안에서는 selftest
  `update.passesOver32MiB`(번들·설치본 둘 다). 끝에서 끝: CI 단계 `in-app-update` 의 `long` 시나리오가 크기보다 1 B 긴 본문이 상한에서
  끊기는 것(`URLError -1103`)을 본다. **잠복이 아니게 됐다:** 이 브랜치의 설치 파일은 이미 33,970,371 B 로 32 MiB 보다 415,939 B 크다(scratch run
  43780695861, `in-app-update` 의 `ok` 가 그 파일을 받아 설치) — 기본 상한을 물려받았다면 첫 앱 안 업데이트부터 조용히 페이지로 떨어졌을 것이다.
  Task 4 의 피드 테스트(200 MiB 경계 `209,715,200` 통과)는 피드 자신의 범위만 고정할 뿐 이 결함을 지키지
  않는다 — 다른 경로로 통과하는 테스트를 가드라고 부르지 않는다(처음 넣었던 32 MiB + 1 B 테스트 둘은 그래서 뺐다).
  **규칙:** 새 다운로드(기존 이음매의 새 호출부도)는 자기 상한과 마감을 이름으로 적는다 — 다른 호출부를 보고 정한 기본값을 물려받지 않는다.
  상한을 정할 때는 실제로 가장 큰 페이로드를 재서 값과 출처를 적고, 여유가 2 배 미만이면 그 자리에서 고친다.

- **Inno Setup 의 롤백은 덮어쓴 파일을 되돌리지 않는다 — "업데이트가 실패하면 이전 앱이 돌아온다"(8단계 계획 D8 7단계)는 전제가 틀렸다 (출시 전 발견).**
  Inno 6.7.1 소스(`Setup.Install.pas`, `Setup.UninstallLog.pas`): 기존 파일은 `DeleteFile` 한 뒤 임시 파일을 `MoveFile` 로 들이고(사본을 두지 않는다), 중단 때의
  롤백(`PerformUninstall(False)`)은 이번 설치가 *새로 만든* 파일만 지운다 — 덮어쓴 파일에는 `utDeleteFile_ExistedBeforeInstall` 이 붙어 새 내용 그대로 남는다.
  러너 실측(보호를 뺀 결함 주입, exe 를 쓴 뒤 복사 실패): 47개 중 44개가 새 파일로 남았다. 복사 도중 멈춘 업데이트는 섞인 설치를 남기고, 버전 파일이 먼저 바뀌면 앱이 실패를 성공으로 읽는다.
  **첫 고침도 틀렸다 — 보호가 "누가 Setup 을 시작했나"에 달려 있었다 (리뷰가 찾음).** 처음엔 `ssInstall` 에서 앱 폴더를 `.previous` 로 *이름만 바꿨다*. 그런데 앱은
  설치 폴더를 작업 폴더로 갖고 시작되고(`[Run]`·시작 메뉴 바로 가기·재실행 모두), 앱이 시작하는 Setup 의 로더도 그 폴더를 물려받아 끝까지 쥔다 — 어떤 프로세스의 작업 폴더인
  폴더는 이름을 바꿀 수 없다. 러너에서 Setup 을 설치 폴더에서 시작하자(`-WorkingDirectory`) "could not move … updating in place" 와 47개 중 44개 새 파일
  (run 43755066548, 고치기 전). 또 이름 바꾸기와 복사 끝 사이에 Setup 이 죽으면(전원, "그래도 종료") 앱 폴더가 비어 실행할 앱이 아예 없었다.
  **왜 못 걸렀나:** CI 업그레이드 단계는 성공 경로만 밟았고 계획은 문서의 "rolls back" 을 "원래대로"로 읽었다. 첫 고침의 시나리오는 모두 pwsh 가 작업 공간에서 Setup 을
  시작했다 — 실제 경로(앱이 자기 폴더에서 시작)와 다른 경로로 통과해 안심을 줬다. "죽은 Setup" 은 시나리오에 없었다.
  **고침:** `PrepareToInstall` 이 앱 폴더를 `…\PokeTokenBar.previous` 로 *복사*하고(완료 표시 파일을 마지막에), 복사를 못 하면 아무것도 건드리지 않고 멈춘다(exit 7, 옛 앱 재실행).
  Inno 는 제자리로 업데이트하고 exe 와 버전 파일이 맨 끝이다 — 앱 폴더는 이름이 바뀌거나 비지 않아 중간에 죽어도 실행된다. 끝나지 못한 설치는 바뀐 파일만 사본에서 되돌리고
  (크기·시각이 같으면 그대로, 다르면 300 ms × 10 재시도), 되돌리기에 실패하면 앱을 켜지 않고 사본을 남긴다. 남은 사본은 앱 폴더가 온전하면 지우고, 아니면 먼저 되돌린다.
  두 Setup 이 서로의 사본을 지우지 않게 `Local\PokeTokenBar-Setup` 뮤텍스를 앱을 닫기 *전에* 검사한다(Inno 의 `SetupMutex` 지시어는 `InitializeSetup` 뒤, 앱을 이미 닫은 뒤에 검사한다).
  앱은 시작하자마자 작업 폴더를 로그 폴더로 옮긴다(`WindowsInstall.leaveInstallFolder`) — 브라우저·CLI·Setup 이 설치 폴더를 물려받지 않는다.
  **같은 부류 스윕:** 호출자의 작업 폴더에 기대는 곳 — 앱의 `ShellExecuteW`(폴더 인자 없음)·`Process` 실행·Task 6 의 Setup 실행이 모두 작업 폴더를 물려준다(앱 쪽 고침으로 닫힘;
  Task 6 은 Setup 에 설치 폴더 밖 작업 폴더를 명시한다). 폴더 이름 바꾸기에 기대는 코드는 이제 없다. `MinVersion`·아키텍처 거절은 `[Code]` 전이라 아무것도 닫지도 켜지도 않는다(exit 1).
  **규칙:** 외부 도구의 실패 의미(롤백·원자성)는 소스와 강제 실패로 확인하고, 실패 경로 테스트는 "실패 뒤 디스크에 무엇이 있나"(내용 해시)를 본다. 시나리오는 실제 호출자와
  같은 조건(작업 폴더, 앱이 이미 끝난 순서, 동시 실행, 강제 종료)에서 돌린다.
  **회귀 점검:** `windows-app.yml` 단계 `failed-update-relaunch`(`fromAppFolder`, `inAppOrder`, `failDuringCopy`, `backupFails`, `failedRestore`, `twoSetups`, `staleComplete`,
  `staleIncomplete`, `killedMidCopy`) — 결함 주입(되돌리기 제거, 뮤텍스 검사 제거, 되돌리기 실패 뒤 재실행, 남은 사본 되돌리기 제거, 복사 실패 무시)이 각각 해당 줄을 FAIL 로 만든다.
  셀프테스트 `packaged.workingFolder` 는 작업 폴더 옮기기를 빼면 FAIL.
  **2차 리뷰 — 같은 상태를 두 규칙이 다르게 읽었다.** 완료 표시가 있는 남은 사본은 "앱 폴더에 exe 와 버전 파일이 있으면" 지웠는데, 표시된 사본이 남는 상태(쓰는 중·되돌리는 중
  강제 종료, 되돌리기 실패)는 모두 exe 와 버전 파일을 가진 *섞인* 폴더다 — 다음 Setup 이 하나뿐인 온전한 사본을 지우고 섞인 폴더를 백업했고, 그 Setup 이 실패했다면 앞 Setup 이
  켜기를 거부한 폴더를 되돌려 켰을 것이다. 이제 사본은 앱 폴더의 버전 파일이 사본과 *다를* 때만 지운다(버전 파일은 맨 마지막에 쓰고 되돌릴 때는 맨 먼저 되돌린다). 남은 사본을
  못 되돌려 멈출 때도 `RestoreFailed` 로 켜지 않는다. **그리고 "바뀌지 않았다"는 내용으로 판단한다:** 크기·시각만 보던 규칙은 하네스에서 간헐적으로 vN+1 버전 파일을 vN 것으로
  봤다 — Inno 는 설치 파일 시각을 2 초로 반올림하고(`TimeStampRounding`) 버전 파일은 버전 사이에 길이가 같다. `RestoreFile` 은 SHA-256 을 비교한다.
  **왜 못 걸렀나:** 남은 사본 시나리오가 "앱 폴더와 같은 내용의 사본"만 만들어 두 규칙이 갈리는 상태(섞인 폴더 + 같은 버전)를 한 번도 만들지 않았고, 테스트 페이로드가 모든 파일의
  크기를 바꿔 시각 비교를 시험하지 않았다. 간헐 실패는 결함 주입 실행에서만 보였다 — 주입과 상관없는 시나리오가 깨지면 플레이크로 넘기지 말고 원인을 찾는다.
  **회귀 점검(추가):** `failLate`(버전 파일까지 쓴 뒤 실패), `killedDuringRestore`, `killedFirstEntry`, `leftOverRestoreFails`, `noVersionFile`, `partialCopy`, `appFolderMissing`; 페이로드의
  `THIRD-PARTY.txt` 는 크기·시각이 같고 내용만 다르다. 결함 주입: 옛 규칙, `RestoreFailed` 빼기, 폴더 다시 만들기 빼기, 크기·시각 비교, 버전 파일 먼저 빼기, exe 만으로 "온전".

- **앱 안 업데이트의 테스트 둘이 실행 환경 덕에 통과했다 (stage 8 Task 6, 병합 전).** ① `WindowsUpdateInstallerTests.testSetupsArgumentsAreExactAndTheLogPathIsQuoted`
  가 URL 을 `==` 로 비교했다 — corelibs 의 `appendingPathComponent(_:)` 는 디스크를 물어 폴더가 있으면 끝에 `/` 를 붙인다(`PlatformCompat.logsDirectory()`).
  전체 스위트에서는 다른 테스트가 Logs 를 먼저 만들어 통과했고(windows run 43778115607), 필터해 돌린 결함 주입 실행에서만 실패했다(scratch run
  43780695861). 고침: 경로(`WinPath.native`)로 비교. ② e2e 스크립트(`in-app-update.ps1`)가 앱 로그를 `[IO.File]::ReadAllText` 로 읽었다 — 읽기
  공유만 주므로 앱이 쓰기로 연 동안 공유 위반(결함 주입 실행 8 회 중 1 회, run 43780709740). 고침: 읽기·쓰기·삭제 공유로 연다.
  **왜 못 걸렀나:** 둘 다 첫 실행(전체 스위트, 대조 실행)에서는 맞는 상태가 우연히 갖춰져 있었다 — 결함 주입 실행이 다른 테스트 선택과 타이밍을 줘서
  드러났다. **스윕:** 이 작업의 다른 URL 비교는 `standardizedFileURL`·`.path`·같은 객체로 한다; 스크립트의 다른 로그 읽기는 `Get-Content`(쓰기 공유).
  **규칙:** 윈도에서 있을지 없을지 모르는 폴더의 URL 은 경로로 비교하고, 다른 프로세스가 쓰는 파일은 쓰기 공유로 연다.

- **무인(silent) 경로는 사람을 기다리지 않는다 — 앱이 안 닫히면 조용한 Setup·제거가 아무도 누를 수 없는 확인 창에서 영원히 멈췄다 (stage 8, 출시 전).**
  `InitializeSetup`·`InitializeUninstall` 은 앱이 15 초 안에 안 닫히면 `[Code]` 의 `MsgBox` 를 띄웠다. Inno 의 `MsgBox` 는 억제 불가로 등록돼 있어
  (`Setup.ScriptFunc.pas`: `Suppressible := False`) `/SUPPRESSMSGBOXES` 를 무시한다. 러너 재현(run 43819088565, 앱 뮤텍스를 쥐고 `WM_CLOSE` 에 답하지 않는
  도우미): 앱 안 업데이트 스위치의 조용한 Setup 이 15.8 초 뒤 "Message box (OK)" 를 화면에 띄우고 120 초가 지나도 끝나지 않았고, 조용한 제거도 같았다. 남은
  제거 프로세스는 `unins000.dat` 를 쥐고 있어 뒤따른 모든 Setup 이 사본을 못 만들어 거절했다(exit 7). 사용자 PC 에서는 앱이 이미 끝난 뒤의 앱 안 업데이트가
  눈에 잘 안 띄는 확인 창 하나에서 멈춘다. Inno 자신의 확인 창(AppMutex, Restart Manager, 파일 오류, MinVersion, 제거의 실행 중 확인)은 모두 억제 가능이고
  기본값이 Abort/Cancel 이라 기다리지 않는다 — 기다린 것은 우리 코드 둘뿐이었다.
  **고침:** 둘 다 `PTB setup:`/`PTB uninstall:` 한 줄을 남기고 `SuppressibleMsgBox` 를 쓴다(대화형에서는 그대로 보이고, 조용하면 기록만 하고 끝난다: Setup
  exit 1, 아무것도 건드리지 않고 앱 뮤텍스가 남아 있으니 다시 켜지도 않는다). 기다림은 이름 붙은 30 초(`CloseWaitSeconds`). 그 뒤엔 죽이지 않고 거절한다 —
  죽이면 앱의 종료(설정 동기화, 팀 연결 정리)를 건너뛰고, 30 초 동안 `WM_CLOSE` 에 답하지 않는 앱은 사용자를 기다리는 중일 수 있다.
  **왜 못 걸렀나:** 앱 닫기 시나리오는 모두 잘 닫히는 앱만 썼고, CI 도우미는 시간 제한이 있었지만 로더만 죽이고 기록 없이 실패했다(Setup 의 .tmp 와
  제거기의 `_unins.tmp` 는 살아남았다). 몇 단계는 `Start-Process -Wait` 에 단계 시간 제한도 없었다. 멈춘 run 43808578589 의 원인은 이것이 아니었다
  (주석: "The hosted runner lost communication with the server"; 그 단계는 Setup 을 180 초로 묶고 있었다) — 가설을 확인하다 실제 결함을 찾았다.
  **규칙:** 조용한(무인) 실행에서 닿을 수 있는 모든 확인 창은 억제 가능해야 하고(`[Code]` 에 `MsgBox`/`TaskDialogMsgBox` 금지), CI 가 Setup·제거를 돌릴 때는
  언제나 시간 제한이 있는 도우미로 돌린다: 넘기면 화면의 창 이름을 남기고 Setup·제거 프로세스를 모두 죽이고 setup 로그를 붙여 실패한다.
  **회귀 점검:** `failed-update-relaunch` 의 `appDoesNotClose`·`uninstallAppDoesNotClose`(30 초 근처에 스스로 끝남), `Invoke-Setup`(`ci-helpers.ps1`);
  결함 주입(`MsgBox` 되돌리기)에서 두 시나리오가 120 초 제한에 걸린다.

- **lost runner in the update jobs — 실행 중이거나 막 닫힌 앱을 만난 Setup 의 Restart Manager 단계가 GitHub 호스트 VM 을 통째로 잃게 했다 (2026-11-17 부터, 2026-11-25 규명).**
  **증상:** `windows-app.yml` 의 "Failed update and in-app update" 단계 "The in-app update from a loopback feed" 가 끝나지 않고 job 이 "The hosted runner lost
  communication with the server" 로 끝났다(로그·아티팩트 없음, 25 분 단계 제한도 안 걸림). 2.5.641 릴리스부터 5 번 중 3 번이라 2.5.640..641 회귀로 보였다.
  **회귀가 아니었다:** 같은 주석이 windows-port 에서 11-17~19 에 updates job 6 번, installer job 의 "Upgrade over a running instance" 단계 2 번 나왔고(예: 44236491001,
  44401819868), v2.5.640 빌드와 v2.5.642 빌드를 같은 시각 12 대씩 돌리자 1/12 대 1/12 였다. 2.5.635~640 의 연속 6 번 통과는 운(그 비율에서 20~50 %)이었다.
  **잃는 시점(로그 없이 잰 방법):** 러너 `_diag` 로그상 Listener 는 1 분마다 잡 잠금을 45 분 연장한다 → 잃음 판정 시각 − 45 분 ≈ 마지막 연장. 그리고 예약 작업
  (Interactive·S4U, 둘 다 사전 대조로 동작 확인)이 30 초마다 check run 을 올렸다(curl.exe 와 .NET 둘 다): 죽은 VM 은 둘 다 그 순간 멈췄다 — 세션만이 아니라 VM(또는 그 네트워크)
  전체가 사라진다. 시점은 매번 Setup 이 실행 중·막 닫힌 앱을 만나는 구간(ok·failCopy·failPrepare 의 앱이 띄운 Setup, 업그레이드 단계)이었다.
  **원인 범위 좁히기(각 20~24 대):** http.sys 피드 대신 사용자 모드 소켓 피드도 3/10 으로 같았다(무관). 앱 혼자(가짜 Setup 을 받아 실행·종료, ~360 회) 0, 앱 없이 Setup 만
  (~150 회) 0. **"실행 중인 앱 위로 업그레이드" 9 분 루프: `CloseApplications=yes` 4/10 대 VM 소실(주기당 ~2 %), 같은 루프를 `CloseApplications=no` 로 다시 만든 설치 파일로는
  0/10(~340 회), `/NOCLOSEAPPLICATIONS` 로도 0/6.** 통틀어 Restart Manager 단계 켬 11/24, 끔 0/30. 통과한 로그 90+ 개 모두 "RestartManager found no applications" —
  죽는 주기에 RM 이 무엇을 찾아 무엇을 닫는지는 보지 못했다(그 주기의 로그는 VM 과 함께 사라진다). 러너는 `hosted-compute-agent`(Runner.Listener 의 부모)가 Windows Terminal
  콘솔(전경 창)에서 돈다 — RM 이 그 계통을 건드리는 것이 가장 유력한 가설이나 **미확인**.
  **고침:** `installer/PokeTokenBar.iss` `CloseApplications=no`. 앱은 우리 `[Code]` `CloseRunningApp`(WM_CLOSE 후 뮤텍스 대기)이 이미 닫는다. 그 밖의 프로세스가 파일을 쥐고
  있으면 이제 Setup 이 그것을 닫지 않고 실패해(exit 5) 이전 앱을 되돌린다 — `lockedFile`(.txt) 와 같은 경로.
  **왜 못 걸렀나:** updates job 은 level full(릴리스·디스패치)에서만 돌고, 잃은 러너는 로그를 남기지 않아 11-17~19 의 8 번은 원인 없이 묻혔다(43808578589 는 "이것이 아니었다"
  로만 남았다). 6 번 연속 통과를 회귀 창의 증거로 읽었다 — 간헐 결함에서 통과 횟수는 비율과 함께만 의미가 있다.
  **규칙:** (1) 잃은 러너는 한 번이라도 부류로 기록하고, 원인 조사는 VM 밖으로 나가는 채널(예약 작업의 check run 심장박동, 단계 이름 비콘)로 한다. (2) 간헐 실패의 "회귀 창"은 이전
  빌드를 같은 시각 같은 수로 나란히 돌려 확인한다. (3) 설치 파일은 다른 프로세스를 닫는 Inno 기능(Restart Manager)을 쓰지 않는다 — 닫을 것은 우리 코드가 이름으로 닫는다.
  **회귀 점검:** `InstallerRestartManagerScanTests`(.iss 의 `CloseApplications=` 가 정확히 `no` 하나; `yes` 주입·v2.5.642 의 .iss 로 실패 확인). 검증 실행: diag/update-runner-loss-2
  의 45484521499(고친 설치 파일로 job 그대로 8/8)·45487905463(커밋된 .iss 로 만든 설치 파일: failed-update 단계 + in-app 단계 3 회씩 12/12 통과, 같은 시각 옛 설치 파일 4 대 중 3 대 소실).

## 윈도 로케일·알림 (windows-port)

- **한국어 윈도에서 앱이 영어로 떴다 — swift-foundation 이 비 Apple 플랫폼에서 `Locale.preferredLanguages` 를 `["en-001"]` 로 고정한다.**
  사용자 PC(윈도 11, 표시 언어 한국어)의 트레이 메뉴가 영어였다. `AppLanguage.systemDefault` 는 `Locale.preferredLanguages.first` 를 쓰는데,
  swift-foundation `Locale_Cache.swift` 의 `#else`(= `FOUNDATION_FRAMEWORK && !NO_CFPREFERENCES` 가 아닌 쪽)가 `languages = ["en-001"]`,
  `locale = "en_001"` 을 하드코딩한다. 러너 실측: `Locale.preferredLanguages=["en-001"]`, `Locale.current=en_001`, 같은 순간
  `GetUserPreferredUILanguages=["en-US"]`. 즉 "비어 있다"가 아니라 **언제나 영어 한 개**라 어떤 PC 에서도 영어가 된다.
  **왜 못 걸렀나:** 테스트가 `AppLanguage.systemDefault(for:)` 순수 함수에 문자열을 주입해 통과했고(`CompanionTests`), 실제 `Locale.preferredLanguages`
  를 윈도에서 읽는 경로는 한 번도 밟지 않았다 — 주입 검증은 "매핑이 맞는가"에만 답한다. 러너가 영어라 CI 도 영어가 "정답"이었다.
  **고침:** `PlatformCompat.preferredUILanguages` (맥: 정확히 `Locale.preferredLanguages`, 윈도: `GetUserPreferredUILanguages(MUI_LANGUAGE_NAME)` →
  비면 `GetUserDefaultLocaleName`) 를 만들고 `CompanionModel.swift` 의 한 줄만 그리로 돌렸다. 맥과 같게 **첫 항목만** 본다(첫 항목이 미지원이고 둘째가 지원이어도 영어).
  **이미 "en" 이 저장된 설치:** `CompanionState.language` 는 신규 설치 때 감지값이 그대로 저장된다(맥도 같다). 윈도엔 언어 설정 UI 가 없어 "en" 은 아무도 고른 적 없는 값이다 →
  `WinUILanguage.migrateStoredLanguage` 가 설치당 **한 번** "저장된 en + 감지값 ≠ en" 이면 감지값으로 바꾼다(`windows.languageDetectionMigrated`). 한 번뿐이라 이후 사용자가 고른 영어는 지켜진다.
  **같은 부류 스윕:** `Locale.current`/`autoupdatingCurrent` 는 윈도에서 늘 `en_001` — `NumberFormatter` 의 `TokenFormatter.grouped`(팝오버 UI, 윈도엔 아직 없음), `Calendar.current.firstWeekday`(= 월요일 고정; 잔액 요약·히트맵 UI, 아직 없음)가 영향권이다. 트레이 요약 숫자는 `String(format:)` 이라 무관.
  표시 로케일이 명시된 곳(`displayLocale`, `en_US_POSIX` 포매터)은 안전. **7단계(UI)에서 `PlatformCompat` 로 지역 로케일·첫 요일을 윈도 값으로 돌려야 한다.**
  **규칙:** 플랫폼 로케일 API 는 값이 "있다"가 아니라 "사용자 것인가"를 실측한다 — 윈도에서 `Locale`·`TimeZone` 을 새로 읽는 코드는 `language.detect`/`timezone.matchesWindows` 류로 OS API 값과 맞대어 본다.
  **회귀 점검:** `UILanguagesTests`(ko/ja/en/zh→en/빈 목록→로케일명/첫 항목 미지원), `WinUILanguageTests`(주입 + 실제 API 가 비어 있지 않음 + 마이그레이션 한 번), 셀프테스트 `language.detect`, `check-language.ps1`(`--inject-ui-language ko-KR` 로 트레이 문자열·첫 실행 안내·마이그레이션).
  러너엔 한국어 언어 팩이 없어 `GetUserPreferredUILanguages` 자체를 한국어로 바꿀 수 없다(HKCU `PreferredUILanguages` 를 써도 en-US) — 그 읽기만 사용자 PC 에서 확인한다.

- **같은 뿌리의 두 번째 결함: 한국어 윈도에서 `TimeZone.current` 가 GMT 가 된다 — "오늘"이 UTC 로 계산된다.** swift-foundation `TimeZone_Cache.swift` 는 `TIME_ZONE_INFORMATION.StandardName` 을 ICU 의
  `ucal_getTimeZoneIDForWindowsID` 에 넣는데, `StandardName` 은 **현지화된 이름**("대한민국 표준시")이고 ICU 는 영어 윈도 존 ID("Korea Standard Time")를 기대한다. 실패하면 GMT.
  러너 실측: UTC 존의 `StandardName`("Coordinated Universal Time")이 ID("UTC")와 달라 `TimeZone.current=GMT` 였고(영어 OS 에서도 일치하지 않는 존은 같은 결과), `Asia/Seoul` 은 영어 이름이 ID 와 같아 통과했다.
  한국어 PC 에서는 서울 시각 00:00~09:00 에 "오늘"이 어제로 나왔을 것이다(일일 합계·`day_timer`·`localDay`). **왜 못 걸렀나:** CI 가 영어 OS 라 존 이름이 우연히 ID 와 같았고, 서울 시간대 테스트도 영어 이름으로 통과했다.
  **고침:** `WinTimeZone.publishSystemZone()` — 현지화되지 않는 `TimeZoneKeyName` 을 OS 의 `icu.dll` 로 IANA 이름으로 바꿔 프로세스 환경 `TZ` 에 올린다(Foundation 은 `TZ` 를 먼저 읽는다; C 런타임의 사본은 안 건드려 `localtime` 은 그대로). 사용자가 직접 둔 `TZ` 는 건드리지 않는다.
  **첫 시도는 앱을 시작 직후 죽였다:** UTC 존의 ICU 이름 `Etc/UTC` 를 그대로 올리자 `DateFormatter(timeZone: .current)`(= `LocalUsageReader.localDayFormatter`, 기동 경로) 가 Foundation.dll 안에서 트랩했다
  (`0xC000001D`). 단계별 사냥(`--tz-hunt`)으로 좁힌 결과 `GMT`·`GMT+0900`·`secondsFromGMT`·`Asia/Seoul`·`UTC` 는 통과하고 `Etc/UTC` 만 죽는다 — corelibs 가 `Etc/` 이름을 모른다. 윈도 존 UTC 와 "UTC-11"…"UTC+13" 이 그 이름으로 매핑된다.
  그래서 `TimeZoneNames.foundationSafe` 가 `Etc/UTC`→`UTC`, `Etc/GMT+11`→`GMT-1100` 으로 바꾼다. **교훈:** "다른 OS 설정으로 한 번도 안 돌려본 경로"(CI 는 늘 UTC=GMT)는 값을 바꾸는 순간 처음 실행되는 코드다 — 설정을 바꾼 자식 프로세스로 기동 경로 전체를 돌려야 한다(`check-language.ps1` 의 `timezone.noTrap.*`).
  시작 시, 그리고 `WM_TIMECHANGE` 에서 `resetSystemTimeZone()` 직전에 호출한다. **회귀 점검:** `WinTimeZoneTests`(ICU 는 영어 ID 만 알고 "대한민국 표준시" 는 모른다; 게시 후 `TimeZone.current` 일치; 사용자 `TZ` 우선), 셀프테스트 `timezone.matchesWindows`(Win32 오프셋과 대조), `check-language.ps1`(서울·UTC).

- **트레이 풍선이 첫 실행에 사라졌다 — `NIIF_RESPECT_QUIET_TIME` 은 "조용한 시간" 풍선을 큐에 넣지 않고 버린다.** Microsoft 문서(NOTIFYICONDATAW): 새 사용자가 처음 로그인한 뒤 1시간과 OS 설치·업그레이드 뒤에는 이 플래그가 붙은 풍선이
  "큐에 쌓이지 않고 표시 없이 버려진다". 새 PC 에 막 설치한 첫 실행 안내가 정확히 그 구간이다(사용자 PC: 방해 금지 꺼짐, 알림 센터 비어 있음). **확정이 아니라 가장 유력한 원인이다:** 러너에서는 이 플래그의 유무가
  화면에도 `NIN_BALLOONSHOW` 에도 차이를 만들지 못했고(서버 SKU 에 토스트 UI 프로세스가 없어 알려진 정상 소스도 안 보인다), 사용자 PC 확인이 남았다. 두 번째 후보는 AUMID: 설치 프로그램은 바로가기에 `LikelionCampus.PokeTokenBar` 를 달았지만
  프로세스는 한 번도 설정하지 않았다(러너에 윈도가 AUMID 없는 트레이 풍선용으로 `NotifyIconGeneratedAumid_*` 항목을 만든 것이 보인다). **왜 못 걸렀나:** 풍선 "표시됨" 주장이 전부 `Shell_NotifyIcon` 반환값(TRUE)에만 기댔다 —
  API 는 쉘이 호출을 받았다는 뜻일 뿐 보였다는 뜻이 아니다. **고침:** 어떤 종류도 `NIIF_RESPECT_QUIET_TIME` 을 쓰지 않는다(`BalloonFlags.infoFlags`; 방해 금지/집중 지원은 윈도가 토스트를 알림 센터로 조용히 보내므로 플래그가 필요 없다),
  프로세스가 `SetCurrentProcessExplicitAppUserModelID` 로 바로가기와 같은 ID 를 설정하고(스캔 테스트가 `.iss`·Swift 상수를 대조), `NIN_BALLOONSHOW` 를 처리·로그하며 10초 안에 쉘이 "표시됨"을 안 보내면 한 번 "not shown by Windows" 로 남긴다.
  첫 실행 안내도 같은 큐를 탄다. **규칙:** OS 에 맡긴 표시는 반환값이 아니라 OS 의 통지(또는 화면)로만 "보였다"고 쓴다; 셀프테스트 `notify.state`/`notify.shown` 이 사용자 로그에 설정 상태와 통지를 남긴다.

- **전체 테스트 실행에서만 `RedirectHeadersMacTests` 3개가 `-1009`(인터넷 없음)로 실패했다 — 플라자 렌더 테스트가 등록한 `NoNetwork` URLProtocol 이 해제되지 않았다.** `URLProtocol.registerClass` 는
  프로세스 전역이고 `URLSession.shared` 는 그것을 따른다. `PlazaContentRig+Mac.swift` 의 `blockNetwork()` 가 `NoNetwork`(모든 요청을 `notConnectedToInternet` 으로 거절)를 등록만 하고
  풀지 않아, 이후에 도는 스위트의 loopback 요청이 0.000 초에 거절됐다. 알파벳 순으로 `Plaza*` 가 `Redirect*` 보다 앞서 도는 전체 실행에서만 드러난다(`--filter 'PlazaContentPanelsMacTests|RedirectHeadersMacTests'` 로 재현).
  **왜 못 걸렀나:** 각 스위트는 단독(필터) 실행에서 통과했고, 오염 쪽 테스트는 자기 렌더만 검증해 누수를 볼 수 없었으며, 피해 쪽은 등록이 없는 상태에서만 정상이라 순서 의존을 드러낼 기회가 전체 실행뿐이었다.
  **고침:** `blockNetwork(for: self)` 가 `addTeardownBlock` 으로 해제를 건다(호출 4곳). **부류 스윕:** 나머지 `registerClass` 사용처(`ClaudeOAuthFileCredentialTests`, `SpriteAnimationRecoveryTests`,
  `OneShotDataMacTests`, `CredentialSwitchCacheTests`)는 모두 같은 파일에서 `unregisterClass` 한다 — 오염원은 `NoNetwork` 하나였다.
  **영구 캡처:** `NetworkProtocolScanTests` — `registerClass` 가 있는 테스트 파일에 `unregisterClass` 가 없으면 실패(해제를 지우는 주입으로 실패 확인). **규칙:** 프로세스 전역 상태(URLProtocol 등록·환경변수·공유 훅)는 설정하는 쪽이 같은 테스트 안에서 되돌린다.

- **`WindowsPlazaClipboardTests.testABusyClipboardFailsHonestly` 가 러너에서 가끔 실패했다(0.0493 초 < 0.05 초) — 테스트의 하한이 타이머 눈금보다 촘촘했다.** `clipboard.cpp` 의 `openWithRetry` 는
  `GetTickCount64` 로 제한 시간을 잰다. 이 카운터는 타이머 틱(최대 15.6 ms) 단위로만 올라가므로 60 ms 제한은 실제 시간 44.4~60 ms 뒤에 끝날 수 있다. 테스트는 "50 ms 이상 재시도했다"를 요구해 틱 경계에 따라 실패했다
  (#207 이후 실행 43774484787). 제품 동작은 맞다 — 제한 시간은 "대략 이만큼"이고 사용자에게는 300 ms 한도의 16 ms 차이다. **왜 못 걸렀나:** 작업 브랜치의 몇 번 실행에서는 우연히 틱이 맞았다.
  **고침:** 하한을 제한 시간에서 한 틱을 뺀 40 ms 로 둔다. **부류 스윕:** 윈도 테스트의 경과 시간 하한은 그 밖에 `WindowsHTTPFetchTests` 의 두 곳(10 초 중 8 초, 3 초 중 2.5 초)뿐이고 여유가 0.5 초 이상이다.
  **규칙:** 윈도에서 `GetTickCount64`·`Sleep` 으로 잰 시간에 하한을 걸 때는 한 틱(16 ms)을 빼고 건다.
- **IME 가 끝낸 한글 음절이 `?` 로 들어올 자리였다 — `WH_GETMESSAGE` 훅이 `WM_CHAR` 류만 유니코드로 다시 보내고 `WM_IME_CHAR` 는 CF 의 ANSI 펌프에 맡겼다.** (stage 6 Task 11, D13)
  CF 의 펌프는 `PeekMessageA`/`DispatchMessageA` 라, 게시된 `WM_IME_CHAR`(IME 가 끝낸 음절을 앱이 직접 처리하지 않을 때 DefWindowProc 경로로 오는 메시지)의 U+D55C 가 코드 페이지 1252 에서
  `?` 로 바뀐 채 유니코드 창에 도착한다. 러너 실측(ACP 1252, 같은 실행): 우리 창의 입력칸은 "한", 훅이 손대지 않는 창(= 고치기 전 경로)의 같은 EDIT 는 "?".
  **왜 못 걸렀나:** Track B 의 문자 검사는 `SendInput(VK_PACKET)`·게시 `WM_CHAR` 로만 돌았고(러너에 쓸 수 있는 한국어 IME 가 없었다), 광장에는 글을 받는 창이 아직 없어
  IME 메시지를 보낼 대상이 없었다 — `WM_IME_*` 는 "관찰만" 하는 범위(0x0281…0x0291)에 들어 있어 통과가 곧 미검증이었다. **고침:** 훅의 재전송 목록에 `WM_IME_CHAR`(0x0286) 한 줄.
  **스윕:** 문자를 wParam 에 실어 *게시*되는 메시지는 `WM_CHAR`·`WM_SYSCHAR`·`WM_DEADCHAR`·`WM_SYSDEADCHAR`·`WM_IME_CHAR` 다섯이고 이제 모두 재전송한다. `WM_IME_COMPOSITION` 의 wParam
  (마지막 변경 문자)도 ANSI 로 바뀌지만 EDIT 는 문자열을 입력 컨텍스트에서 `ImmGetCompositionStringW` 로 읽어 영향이 없다. `WM_MENUCHAR`·`WM_CHARTOITEM`·`EM_*` 는 *보내지는* 메시지라 펌프를 거치지 않는다.
  메뉴 루프 안(`inMenuOrMoveLoop`)에서는 지금처럼 다시 보내지 않는다: 팝업 메뉴는 그 동안 스레드의 키보드 메시지를 모두 메뉴 입력으로 읽는다(셀프테스트 `plaza.chatMenu`: 메뉴가 열린 동안
  게시한 문자는 메뉴가 가져가고 훅 재전송 +0).
  **가드(기계):** 셀프테스트 `plaza.imeChar` — 같은 실행에서 우리 필드는 "한", 우리 창이 아닌 EDIT 는 "?" 여야 PASS(ACP 를 함께 남기고, 한글 코드 페이지에서는 결함이 드러날 수 없다고 적는다).
  `plaza.chatTyping`(VK_PACKET 16 단위: 서로게이트·ZWJ 포함, 훅 재전송 16 = 필드 WM_CHAR 16, 중복 0).

- **숨긴 채 닫은 광장을 다시 열면 입력줄 판이 그려지지 않았다 — 창보다 오래 사는 입력줄의 HUD 가 "그리지 않음"으로 남았다.** (stage 6 Task 11 리뷰)
  광장을 최소화(또는 가림·다른 가상 데스크톱)한 채 트레이에서 닫고 다시 열어 Enter 를 누르면 판·테두리·😀·이모지 판 없이 맨 EDIT 만 보였고, 대화
  기록이 올라가지 않았으며, 판 자리를 누르면 장면이 받아 줄이 닫혔다(다음 최소화·복원까지). **직접 원인:** `WinPlazaChatInput` 은 컨트롤러가 앱 수명
  동안 쥐고 창보다 오래 산다. 입력줄 HUD 의 `isRendering` 은 창의 가시성 콜백만 바꾸는데, 새 창의 첫 표시는 보고되지 않는다(`WinPlazaVisibility`:
  첫 표시는 "보이는 상태"가 기본). 컨트롤러는 자기 HUD 를 닫을 때 `true` 로 되돌리지만(`PlazaWindowController` close) 입력줄 HUD 는 아무도
  되돌리지 않았다. **왜 못 걸렀나:** 셀프테스트의 입력줄 검사는 모두 보이는 창에서 열고 닫았고, 숨김→닫기→다시 열기를 밟는 `plaza.close`/
  `plaza.reopen` 은 입력줄을 열지 않았다. XCTest 에는 창 가시성이 없어 `isRendering` 이 바뀌지 않는다 — 두 검사가 결함 경로의 서로 다른 반쪽만 밟았다.
  **고침:** `attach` 가 HUD 를 그리는 상태로 되돌린다(새 창은 보이는 상태로 시작). **스윕:** 창보다 오래 살며 가시성에서 나온 상태를 쥔 것 — 컨트롤러의
  `hud.isRendering`·`rosterModel.isAnimating`(닫을 때 되돌림), 렌더 루프·스테이지·장면(창마다 새로), 입력줄 HUD(이번에 고침) — 그 밖에 없다.
  **가드(기계):** 셀프테스트 `plaza.chatReopenAfterHidden`(최소화→컨트롤러로 닫기→다시 열기→줄 열기: 판이 그려지고 대화 기록이 그 위, 판 클릭은 줄을 닫지
  않음), XCTest `testTheBarDrawsInAWindowOpenedAfterAHiddenClose` 와 주입(`WinChatFaults.keepHiddenAcrossWindows` → 잡힘).
  **규칙:** 창보다 오래 사는 객체가 창의 가시성에서 나온 상태를 쥐면, 창을 붙이거나 떼는 곳에서 그 상태를 되돌린다.

- **글자 수 자르기가 한 글자의 UTF-16 두 반쪽 사이에서 돌았다 — 반쪽을 U+FFFD 로 읽어 다시 써 넣었다.** (stage 6 Task 11 리뷰)
  꽉 찬 줄(60 자)의 가운데에 한 단위씩 오는 입력(VK_PACKET: 터치 키보드, 이모지 도구)으로 😀 를 넣으면, 높은 반쪽만 들어온 순간 줄이 "61 자"(반쪽 =
  U+FFFD)로 읽혀 마지막 글자를 버리고 U+FFFD 를 `WM_SETTEXT` 로 써 넣었고, 낮은 반쪽이 같은 일을 되풀이했다("��", 끝 두 글자 손실). 59 자에서
  끝에 👨‍👩‍👧 를 치면 👨 와 ZWJ 둘이 남았다. **왜 못 걸렀나:** 테스트는 글자를 통째로(문자열 단위) 넣었고, 실제 VK_PACKET 검사(`plaza.chatTyping`)는
  한도에 닿지 않는 짧은 줄이었다. **고침:** 원시 UTF-16 에 짝 없는 높은 반쪽이 있으면 자르기를 미루고(다음 반쪽이 오면 다시), 짝 없는 반쪽이 있으면
  복구된 디코딩을 절대 다시 써 넣지 않는다. **가드:** XCTest `testTheCutWaitsForTheSecondHalfOfACharacter`·
  `testAJoinedEmojiTypedUnitByUnitAtTheLimitStaysWhole` 와 주입(`cutSplitsSurrogates` → 잡힘). **스윕:** 앱이 글을 다시 써 넣는 곳은 자르기와
  `resetField`(빈 줄) 둘뿐이고, 붙여넣기는 반쪽에서 잘린 끝을 버린 뒤 디코딩한다.

- **조합 중인 음절 위에 이모지를 넣으면 음절 앞에 들어갔다('🍜하') — 진짜 IME 는 조합을 끝낼 때 입력칸에 보이던 음절을 먼저 빼고, 확정 글자는 나중에 캐럿에 다시 친다.** (stage 6 Task 11 리뷰)
  러너의 진짜 한국어 IME 로 `gk`(하 조합 중) 뒤 이모지 판의 🍜 를 누르면 "🍜하" 가 됐다(맥은 `unmarkText` 뒤 캐럿 자리에 넣어 "하🍜"). **직접 원인(러너
  추적으로 확인):** `ImmNotifyIME(CPS_COMPLETE)` 안에서 `WM_IME_ENDCOMPOSITION` 이 먼저 와 EDIT 가 글 안의 음절을 지우고(글 ""), 이어 `GCS_RESULTSTR`·
  `WM_IME_CHAR` 가 오지만 실제로 글자를 치는 `WM_CHAR` 는 **게시(post)** 돼 요청이 돌아온 뒤에 캐럿에 들어간다. 그 사이에 넣은 이모지가 앞자리를 차지했다.
  **왜 못 걸렀나:** 스크립트 IME 는 "끝내기"에서 결과 글자를 그 자리에서 `WM_CHAR` 로 동기 전송해 다른 경로로 통과했다. 첫 두 번의 고침도 가설(늦은 END,
  결과 보고 없는 END)로 만든 가짜 IME 에서만 통과하고 러너에서 다시 "🍜하" 였다 — 메시지 순서를 찍어 보기 전에 고쳤기 때문이다.
  **고침:** 입력칸이 음절을 글 안에 보여 주던 경우, 조합 위의 편집(이모지·붙여넣기·단어 지우기)은 글이 확정된 음절을 다시 담을 때(결과를 받았거나 음절이
  빠졌다가 돌아온 뒤, 조합 없음)까지 기다렸다가 음절 뒤에 한다. 0.3 s 안에 안 오면 그때 한다(편집은 잃지 않는다). 선택 테스트가 기다리는 동안 본 메시지를 찍는다.
  **덤으로 생긴 결함(병합 전 XCTest 가 잡음):** 기다림 확인이 depth 0 의 모든 메시지 뒤에 돌며 글을 `WM_GETTEXT` 로 읽었는데, 그 메시지가 같은 서브클래스로
  다시 들어와 확인을 또 불러 무한 재귀(테스트 프로세스 즉사, 앱 선택 테스트는 st.json 없이 멈춤). IME 출력·글 변경 메시지 뒤에만, 재진입 없이 돌린다.
  **스윕:** 스스로 조합을 끝내는 곳 — Enter(끝내기만, 보내지 않음), Esc·닫기(`CPS_CANCEL` 뒤 빈 줄), 포커스 이동(끝낸 뒤 닫히거나 그대로), 이모지·붙여넣기·
  단어 지우기(이번 고침), 글자 수 자르기(조합 중엔 안 함). 진짜 IME 로 Esc·지도 클릭·한도(59 + 한글 + Space)를 확인했다(셋 다 맞음). depth 0 에서 글을 읽는
  곳은 둘 — 글자 수 자르기(`limitPending` 을 먼저 내림)와 이번 확인(필터 + `checkingPending`) — 둘 다 재진입하지 않는다.
  **가드(기계):** `plaza.chatRealIME`(하 + 🍜 → "하🍜", 메시지 순서 출력), XCTest `testAnEmojiWaitsForASyllableTheEndTookOut`(러너의 순서)·
  `testAnEmojiWaitsForALateResultReport`·`testAnEmojiIsNotLostWhenTheIMENeverReports`·`testAnEmojiOverAnInlineSyllableGoesAfterIt` 와 주입
  (`insertOverComposition`·`editBeforeResult`(이전 동작) → 잡힘). **규칙:** 진짜 IME 결함은 메시지 순서를 먼저 찍고, 가짜 IME 는 그 순서를 그대로 흉내낸다;
  서브클래스 메시지 처리기에서 글을 읽는 코드는 그 읽기가 같은 처리기로 돌아온다는 걸 전제로 재진입을 막는다.

- **`PopoverTwinEquivalenceTests.testTheLimitRowFollowsTheMac` 가 바쁜 Mac 에서 가끔 실패했다 — 한쪽은 고정한 `now`, 다른 쪽은 살아 있는 `Date()` 를 읽고 그 차이에 18 ms 허용치를 뒀다.** 행 모델(`LimitsBuilder(now:)`)은 주입한 시각으로, Mac 의 원본 복사본(`MacPopoverOracle.paceFraction`)은 호출 순간의 `Date()` 로
  페이스를 계산한다. 눈금 위치 비교의 `accuracy: 1e-6` 은 5시간 창에서 18 ms 다. 2.2 초짜리 스위트는 통과했고 11.6 초짜리(바쁜 기계)는 실패했다. **왜 못 걸렀나:** 허용치가 "보통 몇 µs 차이"를 가정했고, 빠른 기계의 단독 실행에서는 그 가정이 늘 맞았다.
  **고침:** 기대값을 주입한 `now` 한 개로 계산해 행 모델과 정확히 비교하고(허용치 없음), Mac 복사본의 값은 "주입한 now 의 페이스와 호출 직후 페이스 사이"에 있다고만 단언한다(페이스는 시간에 단조 — 벽시계 허용치가 아니라 경계). `testThePaceFractionFollowsTheMac` 도 같은 방식.
  **부류 스윕:** `PopoverTwinEquivalenceTests+Mac` 의 나머지 `Date()` 는 시각이 주입 인자인 쪽(`LimitsBuilder(now:)`, `resetClockSuffix(now:)`)과 복사본이 함께 읽는 경우뿐이며, `testTheResetClockFollowsTheMac` 는 6시간 경계에서 30 초 떨어진 오프셋만 써 수 ms 차이로 갈리지 않는다.
  **규칙:** 주입한 시계와 살아 있는 시계를 한 테스트에서 비교할 때는 허용치가 아니라 두 시각 사이의 경계로 단언한다. (결함 주입 확인은 하지 않았다: 가드가 아니라 테스트의 단언 방식을 바꾼 것이다.)
- **윈도에서 Claude 로그인 파일이 없으면 새로고침이 "잠시 후 다시 시도하세요"라고 한다 — 시도해도 소용없는 조언이다(P14, 7단계 Task 6).** Claude Code 에 로그인한 적 없는 PC 에서 팝오버의 새로고침(사용자 동작)을 누르면
  `OAuthAccessTokenCache` 가 자격증명 파일을 못 찾고 Keychain 단계로 내려가는데, 윈도의 `readClaudeKeychain`(`Platform/OAuthKeychainUnavailable.swift`)이 `LimitsError.keychainAccessDisabled` 를 던졌다.
  스토어의 `friendlyLimitError` 는 이 오류를 `limitRefreshGeneric`("Claude 한도 조회에 실패했어요. 잠시 후 다시 시도하세요.")로 바꾼다 — 사용자가 Keychain 접근을 끈 맥 사용자를 위한 문구다. 맥은 같은 상황에서
  `keychainUnavailable(errSecItemNotFound)` 를 받아 "Claude 자격증명을 찾지 못했어요. Claude Code 에 로그인하면…"(`limitRefreshNoCredential`)을 보여 준다. 윈도에는 끌 Keychain 이 없으므로 "접근이 꺼졌다"는 사실이 아니다.
  **왜 못 걸렀나:** 윈도 테스트(`testUserRefreshWithoutAFileReportsKeychainAccessDisabled`)가 던져진 **오류 종류**만 고정했다 — 사용자에게 보이는 **문구**까지 가는 경로(스토어의 `limitTokenRefreshError`)는 아무도 밟지 않았고,
  종류와 문구의 대응(`friendlyLimitError`)은 맥 쪽 테스트가 다른 입력으로만 확인했다. 오류 종류를 고정하는 테스트는 그 종류가 맞는 말인지까지는 답하지 않는다.
  **도달 가능성:** 있다 — 윈도 사용자가 Claude Code 없이(Codex 만 쓰거나 아직 로그인 전) 새로고침을 누르면 그대로 나온다. **고침:** 윈도의 Keychain 단계가 맥의 "항목 없음"과 같은 오류(`keychainUnavailable(errSecItemNotFound)`)를 던진다
  (Core 는 건드리지 않고 fork 소유 Platform 파일 한 곳). **부류 스윕(이 오류를 가르는 `UsageStore`/체인의 모든 분기):** `friendlyLimitError`(→ 자격증명 없음 문구, 의도), `isKeychainPromptDeclined`(`errSecItemNotFound` 는 거절이 아니다 → 추가 계정의 프롬프트를
  막지 않는다, 맥과 같다), `firstUsableCredential`(항목 없음은 다음 서비스 이름으로 넘어가 마지막에 같은 오류를 던진다 — 윈도는 서비스 이름이 여럿이어도 읽는 곳이 없어 결과가 같다), `updateAuthExpired`(401/403 만 본다, 무관),
  `ClaudeOAuthLimitsProvider` 의 `keychainAccessDisabled` 재던지기(진짜 비활성만 거친다). Antigravity 의 `UnavailableAntigravityLimits` 는 일부러 `keychainAccessDisabled` 를 유지한다 — 한도 소스가 없다는 뜻이고 UI 는 그 섹션을 숨긴다.
  **영구 캡처:** `ClaudeOAuthFileCredentialTests.testUserRefreshWithoutAFileReportsAMissingCredential`(오류 종류), `testUserRefreshWithoutAFileShowsTheCredentialMissingText`(스토어를 통해 **보이는 문구**를 8개 언어로, `limitRefreshGeneric` 이 아님도),
  `SettingsModelTests.testAMissingCredentialIsWordedAsOneInEveryLanguage`(양쪽 OS 에서 대응 자체). **규칙:** 플랫폼이 없는 기능을 오류로 알릴 때는 "그 기능이 꺼졌다"가 아니라 사용자가 해야 할 일("로그인")을 말하는 오류를 고르고,
  테스트는 오류 종류가 아니라 화면에 나가는 문구에서 끝낸다.

- **윈도 셀프테스트 게이트가 네 번에 한 번꼴로 깨졌다 — 한 상태를 두 쓰는 쪽이 다투거나, 예산이 한 번 잰 값에서 나왔다.** 같은 부류의 여섯 건을 한 번에 근본원인까지 팠다(`windows-app` 43777825521, 43784126850, 43741036674, 43784581694, 43788143040, 43797111060).
  (A) `plaza.hover`/`plaza.cover`/`plaza.dpiPanels`: 컨트롤러의 1초 포커스 틱(`refreshRoster`)이 자기 세션(비어 있음)에서 명단을 다시 만들어 selftest 의 명단 고정물을 덮었다. 40 ms "keeper" 가 되돌렸지만 그 사이에 읽으면 도구 0개·픽셀 0개였다 — 한 상태를 두 쓰는 쪽이 다툰다.
  **고침:** 컨트롤러가 이미 가진 시험 이음매(`focusTickSleep`)에 `PlazaTickGate` 를 꽂아 패널 검사 동안 틱을 붙들고 selftest 가 유일한 쓰는 쪽이 된다(keeper 삭제). 같은 프로세스에서 옛 방식(틱+keeper) 30회: cover 29/30(실패 한 번은 "roster pixels 0"), 새 방식 50회: hover·cover·dpiPanels 50/50, 명단 변조 0. 결함 주입(명단 비움·카드 안 엶·DPI 변경 생략)은 3/3 모두 실패.
  (B) `plaza.close` 핸들 +17: 제품 누수가 아니다. 50회 열고 닫기에서 49걸음 중 43걸음이 정확히 0, 나머지는 프로세스 배경 일이다 — 새 스레드(`CRYPT32` 스레드와 ucrtbase 풀 워커 2개, ntdll TP 워커)와 그 Event 14·WaitCompletionPacket 5·EtwRegistration 4(= TLS 스택이 처음 뜰 때), 풀 워커 하나당 +2. 검사가 "세 번 중 처음→마지막 ≤10" 이라 배경 일이 어느 사이클에 걸리느냐로 갈렸다.
  **고침:** 8번 열고 닫으며 "매 걸음이 늘었을 때만" 누수로 본다(누수는 매번 새고 배경 일은 일부 사이클에만 걸린다). 종류별 핸들 차이(`WinHandleTable`)를 판정문에 남겨 실패가 스스로 설명된다.
  (C) `modalPump.idle` 5 > 4: 한도 `max(3, 메뉴 전 + 3)` 가 창 안의 알려진 깨움을 무시했다. 메인 스레드를 깨우는 것: 30초 안전 flush(10초 창에 3분의 1 확률, 1 cs — 50창 중 13번 1~2 cs), 설정 쓰기 뒤 2초 debounce flush, 하루 타이머, 120초 스토어 갱신(~45 cs; 50창 중 4번). **5 cs 의 정확한 주인은 못 잡았다**(창 안에서 다시 보이지 않았다) — 그래서 한도를 `3 + 5×알려진 깨움 + 60×갱신` 으로 두고, 출처를 모르는 5는 여전히 실패시킨다.
  (F) `ui.kit.idle`(한도 6): 같은 부류 — 갱신이 걸린 창에서 45 cs 로 실패. 같은 방식으로 예산한다. (E) 유휴 게이트 `plaza-visible-120s`: 러너에 GPU 가 없어 WARP 래스터라이저 풀(`ntdll.dll+0x845d0` 시작 스레드)이 프로세스 사이클의 83%·cs 의 84% 를 쓴다 → 프로세스 전체 값은 러너의 소프트웨어 렌더러를 잰다. 우리 스레드(풀 제외)를 예산하고 풀은 정보로 남기며, 프로세스 전체 한도는 폭주 탐지용으로만 느슨하게 둔다(근거 표본은 `windows-app.yml` 주석).
  **왜 못 걸렀나:** 작업 브랜치의 몇 번 실행에서 우연히 통과했고(표본 1~3개), 예산은 한 번 잰 값에 여유를 조금 얹어 정했다. 측정이 "무엇이 그 숫자를 만드는가"(핸들 종류, 깨운 타이머)를 안 남겨 실패해도 원인을 알 수 없었다. 시나리오 중 2는 앞선 검사가 시간대를 밀어야만 드러났다.
  **부류 스윕:** 시간·핸들·문맥전환 예산이 있는 모든 셀프테스트 검사를 표로 정리했다(`selftest-flakes-report.md`) — 여유 30% 미만: `plaza.frames`(틱/초 ≤70, 관측 60~64: 디스플레이 주사율에 묶임), `loop.runLoopTimer`(<250 ms, 관측 205), `modalPump.mainWork` 큐 ≥10(관측 14), `idle.window`(번들 프로세스 51/69).
  **규칙:** (1) 한 상태에는 쓰는 쪽이 하나여야 한다 — 검사가 컨트롤러의 갱신과 경쟁하면 이음매로 컨트롤러를 멈춘다. (2) 예산은 측정된 분포에서 정하고 표본 크기를 예산 옆에 적는다. (3) 깨움·핸들 예산은 알려진 원인(타이머·갱신·새 스레드)을 각자의 카운터로 세어 예산에 넣고, 출처를 모르는 몫은 실패로 남긴다. (4) 누수 판정은 한 번의 총량이 아니라 "매 반복마다 일어나는가"로 한다. (5) 프로세스 전체 숫자는 러너의 소프트웨어 렌더러·배경 스레드를 섞으므로 앱 스레드와 분리해 예산한다. 반복 도구: `windows-app.yml -f flake_loop=N`(번들 selftest 한 프로세스에서 N회, 매 회 값 출력).

- **윈도 셀프테스트 `popover.realClick` 이 세 브랜치에서 한 번씩 실패했다 — 제품은 맞았고, 검사가 두 번째 클릭이 닫는 순서를 하나로
  가정했다.** (Home 43813599073, 대화 줄 43825854006 1차, 43842945406.) 세 번 모두 같은 끝: 넘침 플라이아웃 안의 아이콘을 실제로 두 번째
  누르자 `NIN_SELECT=true closed and not reopened=true (closed by iconClick …, absorbed +0)` — 팝오버는 닫혔고 다시 열리지 않았다. 검사는
  "플라이아웃이 먼저 활성화를 가져가고(비활성화) 토글 가드가 뒤따르는 선택을 흡수한다"(absorbed +1)만 통과로 쳤는데, 셸의 선택이 팝오버가
  아직 활성일 때 먼저 오기도 한다 — 그러면 "열려 있을 때의 선택"으로 닫힌다. 두 순서 모두 올바른 토글이다. 첫 사각형 (790,720,822,768) 이
  작업 표시줄 위인 것은 결함이 아니다: 아이콘이 닫힌 넘침 플라이아웃에 있으면 `Shell_NotifyIconGetRect` 는 `^` 버튼의 사각형을 준다
  (30회 모두 그 자리는 `Shell_TrayWnd`, 누르면 선택 없이 `TopLevelWindowForOverflowXamlIsland` 가 열리고, 사각형은 두 번 읽어 같아질 때
  플라이아웃 안의 (746,663,786,703) 로 옮겨 간다 — 늘 같다, 낡은 값이 아니다). **왜 못 걸렀나:** 검사를 만들 때(리뷰 M6) 러너 실행 몇 번에서
  한 순서만 나왔고(표본 수 회), 판정이 결과(닫힘·다시 안 열림)가 아니라 경로(흡수 +1)였다. **제품 점검:** 제품은 선택을 받는 순간의
  사각형으로 배치한다 — 플라이아웃에서 열면 그 안의 아이콘(30/30, 플라이아웃과 겹치지 않음), 플라이아웃이 닫혀 있을 때 열리면(키·메뉴·
  두 번째 실행) `^` 버튼 위 — 숨은 아이콘이 사는 자리라 맞다. 토글 가드의 아이콘 영역은 클릭 지점 기준이라 같은 데이터로 맞다. 제품 수정
  없음. **고침:** 검사는 아이콘을 먼저 찾고(셸 사각형 → 눌러서 선택이 없으면 플라이아웃이 자리 잡을 때까지 다시 읽기) 사용자가 받는 결과로
  판정한다: 첫 실제 클릭 → 정확히 한 번 열림, 플라이아웃과 겹치지 않음; 두 번째 → 닫히고 다시 열리지 않음(어느 경로였는지는 기록만).
  같은 프로세스 30회(`-f flake_loop=30`, 43849868002): 30/30, 아이콘 자리 넘침 30, 두 번째 클릭 "비활성화 뒤 흡수" 30 (그 프로세스에서는
  다른 순서 0회; 단일 실행들에서는 약 3/45). 결함 주입: 클릭이 열지 않음 → FAIL(`open=false`), 두 번째 클릭이 두 경로 모두 다시 엶 →
  FAIL(`reopened=true`). **규칙:** 실제 입력 검사는 사용자가 보는 결과로 판정하고, 시스템이 순서를 정하는 중간 경로는 기록만 한다. 경로를
  지키는 가드는 순서를 고정한 합성 검사가 맡는다(`popover.toggle` (a)). **부류 스윕:** 다른 실제 입력 검사 — `popover.dismissInput`(바깥
  클릭·Alt+Tab: 닫힘만), `popover.escape`(닫힘; `NIM_SETFOCUS` 는 시도만 셈), `popover.withPlaza`(포그라운드 복귀: 결과) — 경로를 요구하는
  곳 없음.

- **`PlazaWindowMacShellTests.testASavedFrameWinsOverCentring` 가 게이트에서 한 번 실패했다 — 모니터 배치에 따라 AppKit 이 저장된 창 프레임을 다른 곳으로 옮겨 되살린다.** 3대 디스플레이 맥의 전체 게이트(4761개)에서 `(4430, -87, 700, 532)` 가 나왔다(기대 `(120, 140, 700, 532)`). 테스트는 (120, 140) 에서 저장한 프레임이
  그대로 돌아오길 기대했다. `saveFrame(usingName:)` 문자열(`"120 140 700 532 0 0 1728 1084"`)은 저장 창이 있던 **화면의 사각형**을 같이 담고, `setFrameUsingName`/`setFrameAutosaveName` 은 그 사각형과 지금 화면 배치를 견줘 프레임을 **되살리며 옮긴다**
  (같은 문자열이 화면 사각형만 `0 0 1920 1080` 이면 (101, 141), `0 0 1440 900` 이면 (167, 210) 으로 돌아온다 — 맥 이 배치에서 실측). 어느 화면의 사각형이 "맞는" 것으로 치는지는 메뉴 막대·Dock·활성 화면에 달려 있어, 같은 코드가 같은 맥에서도 그때그때 다른 좌표를 낸다
  (그 뒤 같은 배치에서 같은 테스트는 통과했다 — 게이트 시점의 정확한 화면 상태는 재현하지 못했다). 정확히 4430/-87 의 계산은 못 밝혔다. **제품 동작은 테스트 쪽 문제로 판단**: `open` 은 `center()` 뒤에 복원하고, 이 순서를 뒤집으면 테스트가 실패한다.
  **왜 못 걸렀나:** 이전 게이트들은 같은 배치·같은 화면 상태에서 우연히 저장 좌표 = 복원 좌표였다 — 단일 배치에서 통과한 테스트는 "복원이 프레임을 보존한다"가 아니라 "이 배치에서 변환이 항등이다"를 확인했다.
  **고침:** 기대값을 "저장한 프레임"이 아니라 "AppKit 이 그 이름으로 되살려 주는 프레임"(같은 방식으로 만든 두 번째 창의 `setFrameUsingName` 결과)으로 바꾸고, 그 값이 가운데 정렬 값과 다름을 고정물로 확인한다. `open` 에서 `center()`/복원 순서를 뒤집으면 실패함을 확인했다.
  **부류 스윕:** 절대 창/화면 좌표를 단언하는 맥 테스트는 이것뿐이다(`testRosterCapacityUsesTheRestoredWindowHeight` 는 크기만, `PlazaWindowRig`/`PlazaLiveWindowTests` 는 화면이 닿는 화면 밖 좌표면 건너뛴다, `FloatingPetAgentTests` 는 `visibleFrame` 을 주입한다).
  **열린 의문(제품):** 스크립트 실측에서 두 번째·세 번째 디스플레이에서 저장한 창은 다시 열면 주 디스플레이의 다른 위치로 돌아왔다(저장 사각형의 높이가 `visibleFrame` 과 달라 화면이 안 맞는 것으로 보인다). 앱 밖 스크립트라 메뉴 막대 상태가 달라 단정할 수 없다 — 실제 앱에서는 사람이 확인해야 한다.
  **규칙:** `NSWindow` 프레임 저장·복원 테스트는 "저장한 값"이 아니라 "AppKit 이 그 이름으로 되살린 값"과 견주고, 크기·순서(가운데 정렬 뒤 복원)처럼 배치와 무관한 성질만 단언한다.

- **윈도에서 파일 대화상자·작업 대화상자가 떠 있는 동안 메인 큐가 멈춰 보였다 — 원인은 셀프테스트가 클릭을 메인 큐 항목 안에서 보낸 것이었다 (7단계 Task 15).** 설정 페이지의 내보내기·불러오기가 연 공용 파일 대화상자와 TaskDialog 아래에서 `DispatchQueue.main.async` 블록이 0/10 만 돌았다(러너 실측). 셀프테스트가 `BM_CLICK` 을 `SendMessage` 로 Task(메인 큐 항목) 안에서 보내 모달 루프를 그 항목 안에서 열었기 때문이다 — 직렬 메인 큐는 실행 중인 항목 아래서 아무것도 못 돌린다(키트의 `ui.kit.menuKeys` 가 이미 보인 규칙). 클릭을 `PostMessage` 로 보내 창 메시지에서 열면 `WinModalPump` 의 `WM_TIMER` 틱이 이 대화상자들 아래서도 그대로 돈다(틱 +61, 블록 10/10). 한때 `WH_GETMESSAGE` 훅에서 틱을 더 거는 코드를 넣었으나, 훅 틱을 끈 결함 빌드(`fault/w7-t15-hook`)가 같은 검사를 모두 통과해(훅 틱 +0) 되돌렸다.
  **왜 못 걸렀나:** 처음 실패 때 "대화상자 루프가 타이머를 안 준다"고 가정했고, 클릭 시작 방식이라는 다른 변수를 같이 바꿔 고친 뒤에도 어느 쪽이 효과였는지 가르지 않았다. 결함 빌드로 하나씩 끈 뒤에야 알았다.
  **부류 스윕:** 모달 루프를 여는 곳은 `WinPopupMenu`, 키트의 에디트 메뉴·스크롤 막대 드래그, `WinFileDialog`/`WinTaskDialog` 뿐이다. 앞의 둘은 `modalPump.*`·`ui.kit.editMenu` 가 덮고, 뒤의 둘은 `settings.dialogKeepsPopover` 가 "열린 동안 메인 큐 블록 10/10" 과 소유 관계를 잰다.
  **규칙:** 새 종류의 모달 창을 열 때는 그 창 종류로 "열린 동안 메인 큐가 도는가" 와 "종료 경로가 닫는가"(`settings.dialogExit`)를 러너에서 잰다. 테스트는 클릭을 창 메시지로 보낸다.
<!-- Task 12 (활동 패널) begin -->
- **그림 부품(`WinDrawnView`)을 호스트가 먼저 버리면 비트맵·DC 가 샌다 — 해제가 컨트롤의 `onDestroy` 에 약하게 걸려 있다.** `WinActivitySection.destroy()` 가 뷰 참조를 먼저 `nil` 로 만들고 그 뒤에 페이지가 컨트롤을 부수자,
  `onDestroy` 의 `[weak self]` 가 이미 죽은 뷰를 가리켜 `releaseBitmap()` 이 한 번도 안 돌았다. 증상: 팝오버를 열고 닫을 때마다 GDI +2(DC 와 DIB 섹션) — `popover.openClose3`·`home.openClose3`·`home.activityOpenClose` 가 실패했다(러너 43839371953).
  **왜 못 걸렀나:** 메모리 검사는 열고 닫기 3번 사이의 GDI 증가만 보는데, 그림 부품이 데이터 없이는 비트맵을 만들지 않는 Task 5 의 페이지(한도 막대는 페이지가 뷰를 직접 쥐고 있다)는 같은 경로를 밟지 않았다. **고침:** 섹션이 자기 뷰를 `destroy()` 한 뒤 참조를 놓는다(`destroy` 는 멱등).
  **부류 스윕:** `WinDrawnView(` 를 만드는 곳은 `WinLimitsSection`(페이지가 `bars` 로 쥔다), `WinActivitySection`(고침), 셀프테스트 고정물뿐이다. **규칙:** 컨트롤을 `[weak self]` 로 해제하는 자원은 소유자가 컨트롤보다 먼저 사라지지 않게 하거나, 소유자가 직접 `destroy()` 한다.
- **합성 `WM_MOUSEMOVE` 는 곧바로 취소된다 — 그 창에 진짜 커서가 없으면 `TrackMouseEvent(TME_LEAVE)` 가 즉시 `WM_MOUSELEAVE` 를 올린다.** 호버 검사가 `SendMessage(WM_MOUSEMOVE)` 로 선택을 만들었지만 같은 턴에 떠남 메시지가 선택을 지웠다(카드 "shown=false").
  **고침:** 검사가 `SetCursorPos` 로 진짜 커서를 항목 위에 놓는다(`WindowsSelftestPopoverActivity.cursor(over:)`). 또한 `CGRect.intersects` 는 Windows 에서 모서리만 맞닿은 사각형도 겹친다고 센다(맥은 아니다) — 맞닿음을 단언하는 테스트는 가장자리 좌표를 직접 견준다.
<!-- Task 12 end -->

- **윈도에서 UNC 경로(`\\server\share\…`)를 사용자 지정 스캔 폴더·추가 Claude 폴더에 넣으면 찾지 못했다 — 경로 분해는 드라이브 문자만 루트로 알았고, Foundation 의 경로 정리는 UNC 를 깨뜨렸다(P19, 7단계 Task 14).** 세 군데가 따로 틀렸다. (1) `PlatformCompat.splitRoot` 의 윈도 분기가 `C:` 만 루트로 떼고 나머지는 루트 ""(현재 드라이브의 `/`)로 돌려줘, `CustomScanRoots.expand` 가 빈 조각을 버리며 `\\server\share\logs` 를 현재 드라이브의 `\server\share\logs` 로 찾았다(일치 0). (2) swift-foundation 의 `standardizedFileURL` 은 UNC URL 의 앞 `/` 하나를 지운다(`//localhost/C$/x` → `/localhost/C$/x`) — `ClaudeAccountRoots.roots(from:)` 가 이걸로 존재를 확인해 추가 Claude 폴더도 0. (3) `resolvingSymlinksInPath()` 는 `GetFinalPathNameByHandle` 의 `\\?\UNC\…` 에서 `\\?\` 만 떼어 `UNC/localhost/C$/x` 를 **현재 폴더 기준 상대 경로**로 만든다(러너: `D:/a/PokeTokenBar/PokeTokenBar/UNC/localhost/…`) — `LocalUsageReader.normalizedRoots` 를 거친 모든 스캔 루트와 Aside 의 `state.db` 경로가 엉뚱한 곳을 가리켰다. 셋 다 러너의 관리 공유(`\\localhost\C$\…`)로 실측했다(`WindowsScanRootPathTests.testWhatFoundationMakesOfAUNCPath` 의 `PATH-PROBE` 줄, 실행 43841452367). **왜 못 걸렀나:** Track B Task 4 가 입력이 설정 화면뿐이라 UNC·혼합 구분자를 7단계로 미뤘다(그때는 도달 불가가 맞았다). 기존 윈도 경로 테스트는 전부 드라이브 경로(`C:\…`)라 세 결함 중 어느 분기도 밟지 않았고, Task 1 인벤토리는 코드 읽기로 (1)만 찾았다 — (2)(3)은 Foundation 의 동작이라 읽어서는 보이지 않고 실제 공유 경로로 돌려야 드러났다. 이번에 설정에 그 입력란이 생겨 도달 가능해졌다. **고침:** (1) 순수 함수 `PlatformCompat.windowsSplitRoot` — 드라이브 또는 UNC 의 공유(`//server/share`)가 루트, `\\?\`·`\\.\` 접두어는 벗기고 `\\?\UNC\…` 는 UNC 로; `windowsListablePath` 는 공유 루트 끝에 `/` 를 붙인다. (2)(3) 새 이음매 `PlatformCompat.resolvedFileURL` / `standardizedDirectoryURL`(맥 분기는 예전 식 그대로, 윈도는 UNC 만 `windowsStandardizedUNC` 로 `.`·`..` 를 공유 아래에서 정리하고 공유의 링크는 풀지 않는다)를 Core 네 줄이 부른다: `LocalUsageReader.normalizedRoots`, `CustomScanRoots.normalizedPath`, `LocalAsideUsageReader.databases`, `ClaudeAccountRoots.roots(from:)`. **부류 스윕(공용 코드에서 경로를 나누거나 잇거나 `standardizedFileURL`·`resolvingSymlinksInPath` 로 정리하는 모든 곳):** 위 다섯 곳(고침); `isAbsolutePath`(`\` 로 시작하면 절대 — 이미 맞음), `expandingTilde`·`abbreviatingWithTilde`(표시·`~` 만, 무관), `WinPath.native`(UNC 그대로 `\\localhost\…` — 실측 맞음); 고치지 않은 것과 그 이유: `ClaudeAccountRoots.pathKey`·`keychainServices`(`standardizedFileURL` 경로의 해시 — 식별자일 뿐 찾아가지 않고 모든 호출이 같은 식을 거쳐 일관된다), `ClaudeAccountRoots.discovered`·`defaultRootPaths`·`PlatformCompat.windowsRoamingAppData`·`TeamSettings`·`CursorAuthentication`(홈·앱 폴더: 사용자가 입력하지 않는 로컬 경로), `WinPath.sameFile`(설치·로그 폴더 비교, 로컬). **영구 캡처:** `WindowsScanRootPathTests`(관리 공유로 실제 파일 시스템: 트리거 `testAUNCScanFolderIsFound` 는 수정 전 실행 43841452367 에서 6개 단언 실패, 접힌 루트가 실제로 있는 `//localhost/…` 인지까지; `testAdditionalClaudeFoldersTakeTheSameForms`; `testAProviderDatabaseOnAShareIsFound`), `PlatformPathFormsTests`(양 OS: 모든 형태의 루트, 수정 전 분해를 그대로 옮겨 결함 재현, 맥 이음매 고정), `WindowsSeamScanTests.testTheUserPathsGoThroughThePathSeams`(업스트림 병합이 네 줄을 되돌리면 실패), 셀프테스트 `settings.scanFolders`(설정 입력란에 UNC 포함 다섯 형태, 표시 수 = `survivingExtraCount`). **규칙:** 윈도 경로를 다루는 코드는 드라이브·UNC·장치 접두어 세 형태를 받고, 그 분해는 양 OS 에서 도는 순수 함수로 둔다. Foundation 의 경로 정리(`standardized`, 링크 풀기)는 윈도에서 UNC 를 깨뜨리므로 사용자 경로에는 `PlatformCompat` 이음매로만 쓴다. 경로를 받는 입력란이 생기면 그 형태로 입력 → 저장 → 스캔까지 실제 파일 시스템에서 시험한다.
  **리뷰에서 다시 열림(같은 부류, 원인 3):** 첫 고침은 *사용자가 친 경로*가 UNC 일 때만 링크 풀기를 건너뛰었다. 그러나 `\\?\UNC\…` 는 입력이 아니라 **풀기의 결과**로도 온다 — `net use Z: \\nas\share` 로 매핑한 드라이브의 `Z:\logs`, 공유를 가리키는 링크·정션, subst, DFS. 그 경우 `resolvingSymlinksInPath()` 가 다시 `UNC/nas/share/logs`(현재 폴더 기준 상대 경로)를 만들어 스캔 루트가 없는 곳을 가리켰고, 설정은 여전히 "추가 폴더 1개"라고 셌다(`survivingExtraCount` 는 존재를 다시 보지 않는다). **왜 못 걸렀나:** 스윕이 "사용자가 무엇을 치는가"만 보고 "풀기가 무엇을 돌려주는가"는 보지 않았다; 공유 테스트가 전부 UNC 철자로만 쳤다. **고침(입력 특례 대신 결과를 고침):** 윈도 분기의 `resolvedFileURL` 이 `GetFinalPathNameByHandleW` 를 직접 불러(`WinPath.finalPath`) 그 결과를 순수 함수 `windowsPathFromDevicePath` 로 `\\?\UNC\s\sh\x` → `//s/sh/x`, `\\?\C:\x` → `C:/x` 로 바꾼다 — 매핑 드라이브·링크·정션·subst·DFS 가 한 경로로 맞고(같은 폴더를 드라이브와 공유로 두 번 써도 한 번), 공유 위의 링크도 풀린다; 공유에 떨어진 결과는 아래 원인 4 의 공유 순회가 읽는다(링크 경로 그대로 두면 Foundation 순회가 링크 너머 공유를 빈 목록으로 돌려준다 — 실행 43883084352). 열 수 없는(없는·권한 없는) 경로는 친 그대로 정리.
  **같은 라운드의 원인 4 — 공유 아래는 URL 기반 목록이 비어 있었다(러너에서 측정).** swift-foundation 윈도는 `//server/share/…` 의 어떤 URL 철자(`//`, `\\`, `\\?\UNC\`, 디렉터리 힌트)로도 `enumerator(at:)`·`enumerator(atPath:)`·`contentsOfDirectory(at:)` 가 빈 목록을 돌려준다 — 같은 공유의 파일은 열리고(`fileExists`·수정 시각 OK), 문자열 기반 `contentsOfDirectory(atPath:)` 는 목록을 준다(와일드카드 확장이 그래서 통과했다). 즉 UNC 사용자 폴더는 접힌 루트가 존재하고 설정이 1개로 세도 **스캔은 아무 파일도 읽지 않았다.** **왜 못 걸렀나:** 첫 고침의 테스트는 루트가 *존재함*까지만 확인했고 그 아래 파일을 스캔이 찾는지는 보지 않았다 — 증상(로그가 안 읽힘) 대신 중간 값(루트 경로)을 검증했다. **고침:** Core 의 URL 기반 폴더 순회·목록 8곳(`LocalUsageCache.collect`, `LocalUsageReader` 의 `jsonlFiles`·`embeddedClaudeProjectRoots`·`codexRolloutFiles`, `LocalAdditionalUsageProvider` 의 Kiro·`files(in:)`·OpenCode, `LocalAsideUsageReader.databases`)을 `PlatformCompat.enumerator` / `contentsOfDirectory` 로 돌렸다(맥 분기 = 같은 호출, 맥 테스트가 같은 항목·순서·level 을 고정). 윈도는 공유 아래에서만 `WinShareEnumerator`(문자열 목록으로 깊이 우선, 점 이름 건너뜀, `skipDescendants`·`level` 지원)로 걷는다.
  **같은 라운드의 원인 5 — 드라이브 루트(`C:\`)를 사용자 폴더로 넣으면 기본 루트를 품은 조상인데도 남았다.** 윈도에서 드라이브 루트 URL 의 `.path` 는 `C:/` 라 조상 검사(`k + "/"`)가 `c://` 가 되어 아무 것도 접두하지 않았다(맥은 `/` 를 따로 다룬다, #162-B). **고침:** `CustomScanRoots.normalizedPath` 를 `PlatformCompat.resolvedPath`(맥 = 예전 식)로 — 윈도는 비교용으로만 `C:/` → `C:`.
  **영구 캡처:** `WindowsScanRootPathTests` — `testAMappedDriveFolderIsScanned`(러너에서 `net use` 로 실제 매핑 드라이브: 접힌 루트가 드라이브 철자로 존재하고 그 아래 `a.jsonl` 을 `jsonlFiles` 가 찾음, 추가 Claude 폴더·Aside 도), `testALinkToAShareIsFollowed`, `testAUNCScanFolderIsFound`(공유 루트로 `jsonlFiles` == `["a.jsonl"]`), `testAShareIsWalkedAsALocalFolderIs`(공유 순회 = 같은 폴더의 로컬 순회, `skipDescendants`, Codex·Aside 호출부), `testADriveRootNeverEvictsTheDefaults`; `WindowsSeamScanTests.testCoreListsFoldersThroughTheListingSeams`(Core 에 맨 `enumerator(at:)`/`contentsOfDirectory(at:)` 가 생기면 실패); CI 에서는 공유·매핑이 없으면 건너뛰지 않고 실패. 고치기 전 실패: 실행 43874884946(드라이브 루트 1≠0, 공유·매핑·링크 `jsonlFiles` 빈 목록), 43878279902(측정: 모든 URL 철자가 빈 목록).
  **규칙 보강:** 경로 이음매를 고칠 때는 입력 형태뿐 아니라 OS·Foundation 이 그 경로를 *돌려주는* 형태(장치 경로, 정규화 결과)까지 스윕하고, 테스트는 중간 값(루트가 존재함)이 아니라 증상(그 아래 파일을 스캔이 읽음)까지 간다.

- **응답하지 않는 공유가 설정된 PC(사무실 밖 노트북의 `\\nas\…`)에서는 파일 호출 하나가 SMB 시간 제한(약 20 초)만큼 막힌다 — 기록만, 7단계 Task 14 범위 밖.** (a) 고친 것: 설정의 두 일치 수 계산이 멈춘 공유 경로를 칠 때마다 막힌 협동 풀 스레드를 하나씩 남겼다(취소는 막힌 `fileExists` 를 깨우지 못한다) → 둘 다 직렬 큐 하나(`LatestOnlyWork`, 키마다 가장 새 요청만)로 옮겨 막힌 스레드는 많아야 하나. `LatestOnlyWorkTests` 가 막힌 요청 동안 아무 것도 같이 돌지 않고, 밀린 요청은 가장 새 것만 돎을 고정(동시 큐·취소 없음 주입 시 실패). (b) **고치지 않음, 이유와 함께:** 모든 새로고침이 `CustomScanRoots.expand` 의 `fileExists`(`CustomScanRoots.swift:54`)에서 공유마다 시간 제한만큼 기다리고 그동안 모든 프로바이더가 기다린다(매 폴링); 추가 계정 키 저장은 `UsageStore.saveAccountSessionKey` 가 메인 액터에서 그 폴더의 `.claude.json` 을 읽어(`ClaudeAccountRoots.savedOrganizationID`, `UsageStore.swift:1708`) 서버가 없는 UNC 계정 폴더면 그 시간만큼 UI 가 멈춘다. 둘 다 업스트림 공용 경로(Core)의 구조라 이 작업의 이음매로 고칠 일이 아니다 — 사용자 PC 확인 목록에 넣었다. **규칙:** 사용자가 공유 경로를 넣을 수 있는 곳의 파일 호출은 "몇 초 막힐 수 있다"를 전제로, 메인 스레드 밖에서 하나씩 돌린다.

- **윈도에서 세션 키 파일의 0600 은 아무 것도 막지 않았다 — 평문 키가 `%LOCALAPPDATA%` 의 권한만 물려받았다(7단계 Task 1 발견, Task 14 고침).** `SessionKeyStore.save` 는 맥에서 소유자 전용(0600) 파일을 만들고 쓰지만, swift-foundation 은 윈도에서 `.posixPermissions` 를 읽기 전용 속성에만 대응시킨다(쓰기 비트가 있으면 아무 일도 안 한다). 그래서 윈도의 키는 평문 JSON 그대로, 파일의 ACL 은 상위 폴더 것이었다. **왜 못 걸렀나:** `SessionKeyLimitsTests.testStoreRoundTripsCredentialWithOwnerOnlyPermissions` 가 윈도에서도 돌았지만, 같은 Foundation 이 돌려주는 `.posixPermissions` 값(0600)을 읽어 비교했다 — 보호가 걸렸는지가 아니라 Foundation 이 그 값을 기억하는지를 쟀다. **고침(규칙 5, D14):** 두 줄 업스트림 이음매 `PlatformCompat.writeSecret` / `readSecret`(맥 분기는 예전 호출 그대로) — 윈도는 DPAPI(현재 사용자, 앱 엔트로피, UI 없음)로 암호화해 `WinAtomicWrite` 로 쓰고, 복호화 안 되는 파일은 "키 없음" + 로그 한 줄, 예전 빌드의 평문 파일은 첫 읽기에 같은 자리에서 한 번의 이름 바꾸기로 암호화한다. **부류 스윕:** 공용 코드의 `.posixPermissions`·`0o600` 사용은 이 파일뿐이다(팀 코드는 설정 plist 로 맥에서도 소유자 전용 파일이 아니다 — 다른 부류). **영구 캡처:** `WindowsPopoverSecretTests`(디스크에 키 바이트 없음, 변조·다른 엔트로피·다른 앱의 블롭은 nil, 평문 이전과 이름 바꾸기 중 파일이 사라지지 않음, 로그 한 줄), `WindowsSeamScanTests.testTheSessionKeyFileGoesThroughTheSecretSeams`(업스트림 병합이 두 줄을 되돌리면 실패), 셀프테스트 `settings.sessionKeySave`(UI 로 저장한 파일이 암호화돼 있음). **규칙:** 파일 권한으로 비밀을 지키는 코드는 윈도에서 그 권한이 실제로 걸리는지 OS 의 값(ACL·암호화)으로 확인한다 — Foundation 이 돌려주는 같은 속성으로 확인하지 않는다.

- **종료 경로에 마감 없는 기다림이 하나 있었다 — 팀 소켓 스레드를 `WaitForSingleObject(h, INFINITE)` 와 100 ms 슬라이스 무한 반복으로 기다렸다.** 설치 프로그램은 앱이 닫히길 30초만 기다린 뒤 아무것도 건드리지 않고 거절한다(exit 1, 앱을 죽이지도 되살리지도 않음). 그러니 소켓 스레드가 막힌 호출에서 안 돌아오면 앱이 종료에서 멈추고(트레이 아이콘 유령, 단일 인스턴스 뮤텍스 보유, 업데이트 거절) 사용자는 작업 관리자에서 죽여야 한다.
  **근본원인:** `WinSocketLoop.shutdown()` 이 "스레드는 반드시 돌아온다" 를 가정했다 — 루프가 직접 거는 소켓은 전부 비차단이고 TLS 핸드셰이크도 `WANT_READ/WRITE` 로 단계 진행이라 *지금은* 사실이지만, 그 가정을 지키는 장치(마감)가 없었다. 한 번 지불한 결함(깨움 유실로 귀 먼 루프)의 수리가 "깨움을 다시 보낸다" 였고 그 재전송 루프도 마감이 없었다.
  **왜 못 걸렀나:** 28개 계약 시나리오·소켓 루프 테스트는 모두 *돌아오는* 스레드로만 `shutdown` 을 불렀다. 돌아오지 않는 스레드를 만드는 이음매가 없어, 마감이 있든 없든 같은 경로로 통과했다(트리거 브랜치 = "마감이 터지는 쪽" 이 한 번도 안 밟힘).
  **부류 스윕:** 종료 경로(`WindowsApp.exit`, `WM_CLOSE`/`WM_ENDSESSION`/트레이·홈 종료/업데이트 `onLaunched`)의 모든 기다림 — `exit-deadline-report.md` 표. 마감 없던 것은 소켓 루프의 두 곳(`finished.wait` 반복, `WaitForSingleObject INFINITE`)뿐. DNS-SD 골바이는 이미 0.5초, 나머지(`Shell_NotifyIcon`, 설정 flush)는 OS 호출이라 우리 쪽 기다림이 아니다.
  **고침:** 종료 한 번에 예산 5초(`WindowsApp.exitBudget`). 데이터(팝오버 커밋·설정 flush·백업)를 먼저 쓰고 자르지 않는다 → 트레이 아이콘 제거 → 팀 골바이(최대 0.5초) → 소켓 스레드 대기(예산 잔액, 하한 0.25초). 넘기면 `exit: abandoned <단계> after <ms> ms` 한 줄을 남기고 기존 `exit` 로 프로세스를 끝낸다(`TerminateThread` 없음). 스레드를 둔 채 끝내도 안전한 이유: 스레드가 가진 것은 소켓·`SSL*`·`SSL_CTX` 뿐이고 전부 프로세스 안의 것이라 프로세스가 끝나면 OS 가 거둔다 — 디스크 상태는 이미 위에서 저장했다. 포기한 뒤에는 그 스레드 밑에서 `WSACleanup` 을 부르지 않는다.
  **회귀 테스트:** `WindowsSocketLoopTests.testShutdownAbandonsAThreadThatDoesNotComeBack`(루프 스레드를 `injectStall` 로 막음 → 0.5초 안에 돌아오고 abandon 한 줄), 앱 수준 `exit.stuckSocketThread`(자식 프로세스: 팀 켬 + 답 없는 피어 + 소켓 스레드 막힘 → `WM_CLOSE` → 예산 안에 종료, 트레이 아이콘이 기다림 전에 제거, 뮤텍스 없음). 결함 주입(마감 제거)으로 두 검사 모두 실패함을 확인했다.
  **규칙:** 종료 경로의 모든 기다림에는 마감과 주인(예산을 쓰는 단계 이름)이 있다. "스레드는 돌아온다" 는 가정은 마감 + 돌아오지 않는 스레드를 만드는 시험 이음매 없이는 가정이 아니라 희망이다. 새 기다림(`INFINITE`, `.wait()`, 무기한 `join`)을 종료 경로에 넣으면 같은 PR 에서 `exitBudget` 의 한 몫으로 넣는다.

- **실제 IME 참여 게이트(`chat.realIMEEngaged`)가 라이트 실행에서 제품과 무관하게 깨졌다 — 러너의 TSF 가 두 프로세스 모두에서, 대조 EDIT 까지 참여하지 않았다.** (stage 6 Task 11, 실행 43842945406)
  **직접 원인:** 워크플로 게이트가 "실행마다 적어도 한 프로세스는 참여"를 요구했는데, 라이트 실행은 셀프테스트 프로세스가 둘뿐이고 러너 TSF 의 참여는
  프로세스마다 흔들린다(이전 실행들에서 20 개 중 6 개 불참: 활성화 뒤 TSF 가 한국어/텍스트 서비스라고 보고하면서도 글자를 그냥 통과시킴 4, 활성화 자체가
  안 먹음 2 — 실행 단위로 몰려 나옴). **왜 못 걸렀나:** 게이트를 만든 실행(풀 레벨, 프로세스 넷)에서는 늘 한 곳 이상 참여해, 프로세스 둘에서의 실패
  확률을 재지 않았다. **조사:** 검사가 치기 전에 `g` 로 참여를 확인하고(최대 네 번, 매번 평이한 배열에서 한국어 프로필을 다시 활성화), 시도마다
  TSF 상태·한글 모드·프로세스에 올라온 IMEKR 모듈과 ctfmon/TextInputHost 실행 여부를 찍게 했다. 두 실행(43849832901, 43855461582)에서 5/5 프로세스가
  첫 시도에 참여(TSF 0412/1, 변환 0x1 open=1, imkrtip.dll+imkrapi.dll 적재, ctfmon 실행, TextInputHost 없음) — 불참 경우를 다시 못 봐서 재시도가
  그것을 살리는지는 아직 모른다. **고침:** 검사 안의 규칙은 그대로(대조가 참여하는데 입력칸이 안 하면 FAIL, 둘 다 안 하면 하네스). 게이트는 풀 레벨
  (windows-port 푸시·킷 빌드·릴리스, 프로세스 넷)에서만 필수, 라이트에서는 프로세스별 줄을 단 `::warning::`. **규칙:** 러너 환경에 기대는 게이트는
  그 게이트가 도는 레벨의 프로세스 수로 실패 확률을 먼저 잰다; 불참이 다시 나오면 시도별 기록(IMEKR 모듈 적재 여부)으로 원인을 가린다.
<!-- stage 7 Task 9: the companion header (begin) -->
- **연출 시계가 같은 시각을 다음 마감으로 다시 내놓아 영원히 돌았다 — `Date` 덧셈의 반올림으로 구간 시작 "직전"에 깬 틱.** 윈도 팝오버의 동반자 헤더(stage 7 Task 9)
  `CompanionCelebrationDriver.nextDue(after:)` 는 연출이 움직이는 구간(`[1.3, 1.7]` 같은 닫힌 범위) 밖이면 "다음 구간의 시작"을 마감으로 돌려준다. 시계가 그 시각에 깨면
  `now.timeIntervalSince(start)` 가 `1.3` 이 아니라 `1.2999999…`(시작 시각 + 1.3 을 `Date` 로 더했다 읽은 값)로 나와 다시 "구간 밖, 다음 시작은 1.3" → **같은 마감**을 돌려줬다.
  공용 테스트가 시뮬레이션 루프에서 100% CPU 로 멈춘 것으로 발견했다(사탕 "+XP" 의 1.3 초 지점, `sample` 로 스택 확인). 앱에서는 과거 시각에 한 번짜리 타이머를 다시 무장 → 즉시 발화 → 같은 마감 → 바쁜 루프가 된다.
  **왜 못 걸렀나:** 처음 쓴 시간 계산 테스트는 `t0` 에서 몇 시점을 골라 `effects(at:)` 값만 봤다 — 마감을 따라 걸어가는(시계가 실제로 하는) 경로는 루프 테스트가 처음이었고, 반올림은 시작 시각이 기준일에서 멀 때만 생긴다.
  **고침:** 구간 판정에 1 µs 여유(`timeSlack`)를 두어 구간 시작에 깬 틱은 구간 안으로 치고, 다음 마감은 항상 `now` 보다 뒤가 된다. 흔들림(0.35 초 자세)도 같은 여유로 단계를 센다.
  윈도 쪽 `WinCompanionSection.tickEffects` 는 방어로 `max(마감, now + 1 ms)` 로만 무장한다.
  **부류 스윕:** 다음 마감을 날짜 덧셈으로 만드는 곳 — Task 8 `PopoverSpriteModel.tick` 은 이미 0.5 ms 여유(`slack`)와 "뒤처지면 now 기준" 규칙이 있다, Task 5 `RelativeTimeText.nextChange` 는
  보이는 글자가 바뀌는 다음 후보를 고르므로 같은 시각을 돌려주지 않는다(`PopoverClock` 은 `max(next, now)` 로 무장).
  **영구 캡처:** `CompanionHeaderModelTests.testTheEffectClockAlwaysMovesOnWhateverTheRounding`(기준일에서 먼 시작 시각 다섯 개 × 연출 네 종 + 사탕·민트, 흔들림 50 자세: 모든 마감이 앞 마감보다 뒤, 끝에서 멈춤),
  테스트의 `sample` 헬퍼는 반복 상한과 "마감은 now 뒤" 단언으로 멈추는 대신 실패한다. 결함 주입(`timeSlack` 제거)으로 실패 확인.
  **규칙:** 한 번짜리 시계의 "다음 마감" 함수는 (1) 반환값이 항상 인자 `now` 보다 뒤임을 테스트로 고정하고, (2) 구간·경계 비교에 반올림 여유를 둔다. 시각 몇 개를 찍어 보는 테스트가 아니라
  마감을 따라 걷는 테스트가 시계의 실제 경로다.
- **맥이 `.interpolation(.none)` 을 요청하니 스프라이트가 또렷할 거라 읽고 윈도 팝오버를 최근접(nearest)으로 늘렸다 — 맥 화면은 실제로 부드럽다.** 윈도 팝오버의
  동반자 헤더(stage 7 Task 9). 사용자가 맥·윈도 나란히 시트에서 "맥은 부드럽고 윈도는 각졌다"고 지적했다. `SpriteView.fitted` 는 `Image(nsImage:).resizable().interpolation(.none)`
  인데, 맥의 실제 레티나 스크린샷(`assets/screenshot-collection-pokedex.png`, sRGB 변환)에서 스프라이트 픽셀의 43 % 만 원본 색이었고(최근접이면 100 %, 쌍선형 45 %), 맥의
  `SpriteView` 오프스크린 렌더는 쌍선형과 채널 평균 1.4, 최근접과 6.0 차이였다.
  **왜 못 걸렀나:** 수식어(코드가 요청하는 것)를 읽고 결과 픽셀을 재지 않았다. 나란히 시트는 양쪽을 LANCZOS 로 다시 늘려 붙여서 차이를 흐렸고, 쌍둥이·핀은 코드 본문만 비교한다.
  **고침:** 팝오버 스프라이트 경로(`WinSpriteAnimator`)를 `PopoverSpriteScale.scaledBGRA`(늘릴 때 쌍선형, 줄일 때 모든 원본 픽셀을 세는 텐트 필터)로, 회전도 쌍선형으로. 광장은 자기 픽셀아트 스케일 유지.
  **부류 스윕:** 팝오버에서 최근접을 쓰는 곳 — `PopoverComposite.compose` 의 이미지 늘리기는 파트 그림이 이미 픽셀 크기라 스프라이트가 지나지 않는다(주석의 "crisp" 설명만 남음);
  리캡 카드 등 다른 페이지의 `SpriteSlot` 은 같은 애니메이터라 함께 부드러워진다. 광장(Direct2D nearest)은 맥 SpriteKit `.nearest` 와 같아 대상 아님.
  **영구 캡처:** `CompanionHeaderRendersMacTests.testTheMacShowsItsSpritesSmoothedAsTheWindowsScalerDoes` — 맥 `SpriteView` 를 오프스크린으로 그려 윈도 스케일러 결과와
  최근접 결과에 대 본다(맥이 언젠가 또렷해지면 실패). 결함 주입(스케일러를 최근접으로)으로 실패 확인.
  **규칙:** 맥 쪽 그림을 옮길 때는 수식어가 아니라 맥이 실제로 그린 픽셀(오프스크린 렌더·실제 스크린샷)을 기준으로 삼는다. 비교 시트는 양쪽을 같은 배율로, 다시 늘린다면 최근접으로 붙인다.
- **알 흔들림을 "분당 깨어남 343 번"으로 예산 안이라 셌는데, 유휴 게이트에서 프로세스 컨텍스트 스위치 9441/분(예산 6000)이 나왔다.** 윈도 팝오버 헤더(stage 7 Task 9),
  `popover-companion-wiggle-120s`(run 43889052204, 메인 2176.5/분). **직접 원인:** 흔들림 자세마다 `renderEffectFrame` 이 배경판(회전된 둥근 사각)과 성장 막대 레이어를
  Direct2D 로 새로 그렸다 — 소프트웨어 렌더러의 스레드풀 일꾼 6개가 각각 수천 번씩 깨어났고, 메인도 자세당 여러 번 기다렸다.
  **왜 못 걸렀나:** 비용을 "타이머가 깨는 횟수"로만 셌다. 같은 시간에 잰 bob 은 렌더 없이 애니메이터만 칠해서 깨어남 1 번 = 스위치 1 번(216.5/분)이었고, 그 숫자로 흔들림도 같을 거라 봤다.
  **고침:** `CompanionHeaderPart` 가 배경판을 (배율, 크기, 각도)별로, 막대 레이어를 모양별로 보관한다 — 흔들림 세 자세는 한 번씩만 그려진다.
  **부류 스윕:** 타이머로 렌더를 다시 부르는 곳 — 축하 연출(일시적, 2.6 초 안), 막대 호버(0.48 초), 진화 줄 셰브론 이동(0.25 초)은 끝이 있는 프레임이라 그대로; 상시로 도는 것은 흔들림뿐.
  **영구 캡처:** `CompanionHeaderPartTests.testAnEffectFrameScalesAndTurnsTheSlotAndOnlyItsBoxIsDirty` 가 같은 자세의 그림 재사용을 확인(캐시를 끄면 실패, 주입 확인), 유휴 게이트의 `wiggle` 창.
  **규칙:** 상시 애니메이션의 비용은 깨어남 수가 아니라 측정한 컨텍스트 스위치로 말한다. 한 프레임이 그리기 엔진을 부르면 그 엔진의 일꾼 스레드까지 센다.
- **진화 줄 셰브론을 누르면 "바로 움직였다"가 런마다 달랐다 (`companion.evoLineScroll`, full 43916181737 통과 → light 43941936835 실패, 사이 머지는 무관).** 누름 직후
  `tickLine()` 이 같은 자리에서 `advance(to: now())` 를 불러, `press` 가 시계를 읽은 뒤 흐른 수 µs 만큼 easeInOut 을 적용했다 — 약 1e-7 DIP, `Date()` 가 그 사이 바뀌었는지에 달렸다.
  **왜 못 걸렀나:** 검사가 "정확히 같은 값"을 봤고, 공용 테스트는 `now` 를 고정해 같은 시각만 밟았다. **고침:** 누름은 시계만 무장하고 첫 프레임은 시계가 그린다(`armLine`).
  **규칙:** 시간 곡선은 시작 시각에서 그리지 않는다 — 시작에서의 값은 반올림 잡음만 만든다. 이벤트가 연출을 시작하면 다음 프레임을 무장만 한다.
<!-- stage 7 Task 9: the companion header (end) -->

<!-- plaza window icon (begin) -->
- **윈도 광장 창의 제목 표시줄·작업 표시줄에 앱 아이콘이 아니라 기본 응용 프로그램 아이콘이 떴다 (사용자 PC, 2026-11-17).** 증상: 광장 창 헤더가 "허접"하다는 리포트의 첫째 원인.
  **직접 원인:** exe 의 아이콘 리소스(`PokeTokenBar.rc` 의 `1 ICON`)는 탐색기·설치 프로그램·바로가기에서만 쓰인다. 창은 `WinSinkWindow` 가 `RegisterClassExW` 로 만든 클래스(`hIcon` 없음)이고
  아무도 `WM_SETICON` 을 보내지 않아, 캡션이 있는 최상위 창은 기본 아이콘을 띄운다. 광장 창과 업데이트 진행 창이 같은 경로였다.
  **왜 못 걸렀나:** 아이콘 검사가 exe 파일 쪽(리소스가 들어갔나, 설치 바로가기 아이콘)에만 있었고 "열린 창이 아이콘을 가졌나"를 보는 검사가 없었다. 러너의 selftest 캡처는 클라이언트 영역만 찍어 제목 표시줄이 사진에 없다.
  CI 창 검사는 클래스·스타일·제목만 읽었다. 리소스가 있다는 사실이 창에 아이콘이 있다는 증거로 읽혔다.
  **고침:** `WinAppIcon` 이 exe 리소스를 창의 DPI 에 맞는 크기(`GetSystemMetricsForDpi` 의 SM_CXICON/SM_CXSMICON)로 읽어 큰 아이콘·작은 아이콘을 `WM_SETICON` 으로 건다. `WinSinkWindow` 가 캡션이 있는 모든 창에
  만들 때 적용하고 `WM_DPICHANGED` 마다 다시 적용한다 — 새 최상위 창은 따로 챙길 것이 없다. AppUserModelID 는 프로세스 전체라 이미 모든 창이 같은 값으로 작업 표시줄에 묶인다(팝오버는 도구 창이라 캡션·작업 표시줄 버튼이 없다).
  **부류 스윕:** `RegisterClassExW`/`CreateWindowExW` 전수 — 캡션 있는 최상위 창은 `WinSinkWindow` 경유 광장·업데이트 진행 창뿐(나머지는 selftest 창, 팝오버 팝업·자식 컨트롤, 숨은 sink). 네이티브 `#32770` 대화상자(`TaskDialog`, 파일 대화상자)는 소유 창의 아이콘을 시스템이 쓴다.
  **영구 캡처:** selftest `plaza.windowIcon`, `update.windowIcon` — `WM_GETICON` 큰/작은 아이콘의 비트맵 폭이 창 DPI 의 시스템 지표와 같고 AppUserModelID 가 설치 바로가기와 같은지 본다. 적용 줄을 빼면 실패함을 임시 브랜치에서 확인.
  **규칙:** 창 속성(아이콘·제목·스타일)은 파일이 아니라 열린 HWND 에서 읽는 검사로 고정한다. 새 최상위 창은 `WinSinkWindow` 로 만들면 아이콘이 따라온다.
<!-- plaza window icon (end) -->

## 테스트 하네스 (사용자 화면·포커스)

- **오래된 렌더/히트테스트 시험 13개가 `orderFront`/`makeKeyAndOrderFront` 로 창을 창 서버에 올렸다 — 사용자가 일하는 Mac 에서 `swift test` 마다.** (fx-wintests)
  **직접 원인:** `NSHostingView` 가 레이아웃·렌더되도록 창을 올리는 한 줄을 파일마다 따로 복사했다(좌표 -10000 으로 화면 밖이지만, 두 파일은 `makeKeyAndOrderFront` 라 key 를 가져가려 했다). **왜 못 걸렀나:** 플라자 시험에만 `PlazaNoWindowsOrderedInScanTests` 가 있었고 나머지 시험 파일은 스캔 대상이 아니었다 — 규칙이 한 디렉터리 접두사(`Plaza`)에만 걸려 있어 "모든 시험" 규칙이 아니었다.
  **고침:** 모든 호출을 `window.orderInForTest()`(`LiveWindowTestSupport.swift`, 포크 소유)로 바꿨다. `PTB_LIVE_WINDOW_TESTS` 가 없으면 아무것도 하지 않는다(창 서버에 안 올림); 있으면 화면 밖·일반 레벨 아래·non-key 로 올린다. `NoWindowsOrderedInScanTests` 가 허용 목록 밖 모든 시험 파일의 `orderFront(`/`makeKeyAndOrderFront(`/`NSApp.activate(` 등을 막는다.
  **규칙:** 시험에서 창을 직접 올리지 않는다 — `orderInForTest()` 만 쓴다. 새 시험 파일이 서버 올림을 필요로 하면 이 헬퍼로. 허용 목록에 예외를 더할 땐 이유를 적는다.

- **"오늘 21시"로 장면 시각을 만든 사진 시험이 특정 날짜에만 실패했다 (`PlazaPhotoTests.testPhotoCarriesTheFireAndItsNightLight`, 2026-11-17 전체 게이트 1 실패, 전날까지 통과).**
  **직접 원인:** 광장 아이템은 유닉스 시각을 20분으로 나눈 칸 번호만으로 때·자리·종류가 정해진다(`PlazaItems.spawn(slot:)`). 시험이 `Date()` 의 날짜에 21:00 을 얹어 `scene.now` 로 넣어서, 그 칸의 아이템이 0분에 떨어지는 날에는 땅에 사탕이 놓여 `items.isEmpty` 가 깨졌다. **왜 못 걸렀나:** 시험을 쓴 날과 그 뒤 며칠은 그 칸의 아이템이 아직 안 떨어진 시각이라 통과했다 — 벽시계 날짜가 입력인 줄 모르고 "밤"만 고정했다고 여겼다.
  **부류 스윕:** `Tests/` 의 `bySettingHour … of: Date()` 전수 — `PlazaCampfireSceneTests.at(hour:)` 도 같은 꼴이라 함께 고정했다. `LocalUsageReaderTests:1057` 은 장면이 아니라 로그 날짜 창이라 무관, 나머지는 이미 고정 날짜다.
  **고침:** 두 파일 모두 고정된 날(2026-05-10)의 시각을 쓴다. **규칙:** 장면 시험의 `now` 는 날짜까지 고정한다 — 광장에는 날짜·칸 번호로 정해지는 것(아이템, 계절, 눈 오는 날)이 있다.

## 윈도 팝오버 가독성 (2026-11-17)

- **흰 팝오버에서 3차 텍스트가 흰색처럼 보였다 — 컴패니언 캡션("다음 진화까지 …"), "이번 주/이번 달", 사용량 없음 안내, "갱신 0초", 진화 줄 화살표 (실제 Windows 11 PC 스크린샷 제보).**
  **직접 원인:** 윈도 키트가 Mac 이 잰 라벨 불투명도(`PopoverLabelOpacity`: 2차 0.498, 3차 0.2588)를 검정에 그대로 얹었다. 흰 배경 위 26 % 검정은 대비 약 1.9:1 이고, Windows 의 가는 글리프 렌더링에서는 거의 안 보인다.
  **왜 못 걸렀나:** 캡처를 CI 스크린샷으로 Mac 디스플레이에서 봤고(Mac 글자 렌더링은 같은 값에서도 더 굵다), 색 대비를 재는 검사가 하나도 없었다 — "Mac 값과 같다"를 정확도로 봤지 "읽힌다"를 확인하지 않았다.
  **부류 스윕:** 윈도 팝오버·공용 그리기 부품의 하드코딩 알파/회색 전수. 텍스트·글리프는 모두 두 정의(`PopoverLabelOpacity`, `PopoverColorRole.displayValue`)를 거치게 했고, 라벨 색의 일부 알파로 칠하는 도형(막대·트랙·점·틴트)은 Mac 비율 그대로 `plazaShapeColor` 로 분리했다. 비활성 컨트롤은 `COLOR_GRAYTEXT` 라 그대로 둔다(흐린 게 비활성의 뜻).
  **고침:** 윈도 라이트에서 3차 0.55(#737373, 4.7:1), 2차 0.68(#525252, 7.6:1). Mac 값·골든은 기준으로 그대로. 플랫폼 선택은 `PopoverPlatform.isWindows` 한 곳이고 값은 순수 함수라 Mac 에서 시험한다.
  **영구 캡처:** `PopoverLabelContrastTests` — WCAG 대비(3차 ≥ 4.5, 2차 ≥ 7), 순서, Mac 값 불변을 고정한다.
  **규칙:** 텍스트 색은 값이 아니라 대비로 검증한다. 다른 플랫폼에서 측정한 불투명도는 그 플랫폼의 글리프 렌더링에서도 읽히는지 따로 확인한다.

## 윈도 팝오버 상점·가방 (2026-11-17)

- **상점·가방 카드가 그린 그림 뷰(`WinDrawnView`)를 컨트롤만 돌려주고 끝냈다 — 아이콘·알·배지가 칠해지지 않았고 닫을 때마다 GDI 개체가 남았다 (`popover.tabs` 열고 닫기: warm-up gdi=120 → 136 → 138).**
  **직접 원인:** `WinDrawnView` 는 자기 컨트롤의 `onDestroy` 와 창 핸들러에 `[weak self]` 로만 잡힌다. 다른 페이지는 뷰를 프로퍼티에 들고 있는데(`cardView`, `bars`, …) 새 카드 도우미는 `view.control` 만 반환해 뷰가 곧바로 해제됐다 —
  비트맵과 메모리 DC 는 반환되지 않고, `WM_PAINT` 핸들러는 `self` 없이 아무것도 그리지 않았다.
  **왜 못 걸렀나:** 컴파일은 통과하고 Mac 에서는 이 코드가 돌지 않는다. 구조 검사(`popover.tabs` 의 제목·선택·고정)는 뷰가 그려지는지 보지 않았고, 걸린 것은 우연히 같은 검사 안에 있던 열고-닫기 GDI 수였다 —
  "다 그려졌다"가 아니라 "자원이 돌아왔다"가 결함을 드러냈다.
  **부류 스윕:** `WinDrawnView(` 생성 11곳 전수 — 다른 곳은 모두 프로퍼티·배열에 보관한다(`cardView`, `bars`, `sv/pv`, `noteMade`, `WinSnapshotLead.sprite`, 셀프테스트의 `view/drawn/growing`).
  **고침:** 컨트롤이 파괴될 때까지 뷰를 소유하는 클로저를 건다(`WinCardKit.own`; 컨트롤 파괴가 클로저를 놓으므로 순환은 거기서 끝난다).
  **영구 캡처:** `popover.shop` 이 상점 페이지를 네 번 열고 닫아 GDI·USER·핸들을 `PopoverResourceRule` 로 판정하고(소유자를 빼면 첫 닫기에서 실패), 같은 검사가 아이콘 그림 유무를 본다.
  **규칙:** 그림 뷰를 만드는 코드는 그 뷰를 누가 소유하는지 한 줄로 말한다 — 컨트롤만 반환하는 도우미는 `own(view)` 를 부른다.

<!-- merged-head full run (fix/merged-head-full-run) begin -->
## 윈도 CI 전체 실행 (머지된 헤드, run 43967277783)

- **`popover.realClick` 이 설치본 셀프테스트 두 시도 모두 실패했다 — 러너의 "조용한 시간"(방해 금지)이 부팅 약 1시간 뒤 꺼지자, 우리가 막 올린 풍선이 화면에 뜨는 상태에서 플라이아웃 안 아이콘을 눌렀다.**
  **증거:** `tray-desktop.png`(23:02)에는 시계 오른쪽에 방해 금지 종(zZ)이 있고 00:23 의 `update-tray-menu.png` 에는 없다. 종이 빠지면 알림 영역 전체가 24 px 오른쪽으로 간다 —
  셸 사각형이 첫 시도 안에서 `tray.anchorRect`(85번째 체크, (790,720,822,768))와 `popover.open`(142번째, (814,720,846,768)) 사이에 바뀌었고, 두 번째 시도는 처음부터 (814,…)였다.
  같은 때부터 풍선이 실제로 머문다: 'already-running' 풍선의 표시→시간 초과가 앞쪽은 같은 초, 두 번째 시도는 7 초. 통과한 전체 실행 둘(43916181737, 43922230973)은 설치본 셀프테스트가
  작업 시작 43–46 분 뒤에 이 체크를 지나 조용한 시간 안이었고, 실패 런은 57 분·69 분 뒤였다(작업 시작 22:09:37; 종은 23:02 에 있었고 23:05–23:06 사이에 빠졌다). 실패 모양: 플라이아웃 안 아이콘 사각형 (770,663,810,703) 의 중심을 두 번 눌러
  두 번 다 `NIN_SELECT` 없음, 플라이아웃은 그대로 열려 있음. **원인(재현으로 확인):** 10 초 전 `popover.noSelfOpen`·`popover.refusedForeground` 가 올린 풍선 세 개가
  7 초씩 줄 선 토스트로 오른쪽 아래(플라이아웃 모서리)를 덮었다 — 두 시도 모두 클릭 시각이 둘째·셋째 토스트 구간에 든다. 그 런에는 스크린샷이 없었고 풍선 이벤트 로그는 프로세스당 20 줄 상한에 닿아 있었다 — 설치본 셀프테스트를 조용한 시간 뒤로 늦춘 진단 런(44003693742)에서 새 기다림이 덮개를 `Windows.UI.Core.CoreWindow 'New notification'`(다른 프로세스)으로 5.6·5.7 초 기록한 뒤 클릭이 통과했다(알림 상태 5).
  **왜 못 걸렀나:** 체크가 "아이콘 사각형 = 클릭이 닿는 곳"이라 가정하고 그 지점의 창을 보지 않았다. 지금까지의 모든 런이 이 체크를 조용한 시간 안에서 지나(주석: "every run so far: (790,…)"),
  풍선이 실제 토스트가 되는 상태를 한 번도 밟지 않았다. 위 알림 항목의 "서버 SKU 에는 토스트 UI 가 없다"는 관찰도 첫 1 시간 안(번들 셀프테스트)에서 찍은 캡처였다.
  **고침:** 플라이아웃 안을 누르기 전에 그 지점의 최상위 창이 셸(explorer) 프로세스 것인지 보고, 아니면 20 초까지 기다리며 무엇이 덮었는지 기록한다(`waitUncovered`). 클릭이 아무것도 못 고르면
  그 지점의 창 클래스와 전체 화면(`realclick-flyout-<pid>.png`, 로그 폴더 → collected)을 남기고, 셸 알림 상태(`SHQueryUserNotificationState`: 6 조용한 시간, 5 알림 받음)를 결과에 붙인다.
  **부류 스윕:** 실제 입력(SendInput)으로 화면 오른쪽 아래를 누르는 체크 중 풍선 직후(20 초 안)에 도는 것은 `popover.realClick` 하나다 — 그 사이 체크(menuAfter/menuSettings/secondLaunch/autostartQuiet)는 게시 메시지·키·자식 프로세스다.
  팝오버 안을 실제로 누르는 홈·설정 체크는 마지막 풍선보다 1 분 넘게 뒤라 토스트 수명(7 초 × 줄) 밖이다.
  같은 부류의 두 번째 구성원은 런으로 찾았다: 조용한 시간이 끝난 뒤에 설치본 셀프테스트가 오도록 늦춘 진단 런(44003693742, `flake_loop=40`)에서 `popover.realClick` 은
  "covered by Windows.UI.Core.CoreWindow 'New notification' … for 5.6 s" 뒤 통과했고(알림 상태 5), 대신 `ui.kit.idle` 이 두 시도 모두 메인 cs 12·23(예산 11, 조용한 시간엔 0)으로 실패했다 —
  **원인 미확정(열린 항목):** 우리 풍선 큐가 남아 쉘 보고로 깬다고 보고 큐가 빌 때까지 기다리게 했으나, 다시 늦춘 진단 런(44017021393, 상태 5)에서 큐는 이미 비어 있었고 체크는 cs 2 로 통과했다 — 처음 실패 런의 둘째 시도(상태 5)도 cs 0 이었다. 도달을 보이지 못한 가드라 뺐고, 대신 창 동안의 트레이 콜백 수(`WinTray.callbackCount`)와 알림 상태를 결과에 적어 다음 실패가 쉘의 풍선 보고 때문인지 말하게 했다. 세 번째로 늦춘 런(44026117982, 상태 5)에서 cs 5·루프 반복 7(조용한 시간엔 1)인데 트레이 콜백은 0 — 깨움은 풍선 보고가 아니다(토스트가 뜨고 질 때 최상위 창에 오는 다른 브로드캐스트로 보이나 미확인). 예산 안이라 통과했고 항목은 열려 있다.
  **영구 캡처:** `popover.realClickCovered` — 우리 최상위 창(토스트 대역)이 프로브 중심을 1.5 초 덮는 동안 기다렸다가 프로브가 다시 그 지점의 창이 되는지 본다. 결함 주입(기다림 제거, light 43996842694)으로 "waited 0.0 s … still covered" 실패 확인.
  **규칙:** 실제 입력 체크는 누르기 전에 그 지점의 창이 대상인지 확인한다 — 러너의 화면은 시간에 따라 바뀐다(첫 1 시간의 조용한 시간, 그 뒤의 토스트).

- **`companion.celebrate` 가 이로치 부화로 실패했다(3.10 s > 2.6 s) — "일반 부화" 픽스처가 시스템 난수로 1/64 이로치를 굴렸다.** 3.10 s 는 결함이 아니라 이로치 연출의 설계 길이다
  (`burstHold` 2.6 + `burstFade` 0.5, 맥과 같음; `CompanionHeaderModelTests` 가 3.11 s 에 버스트가 끝남을 고정). 체크 예산 2.6 s 는 일반 부화(섬광과 팝)의 것이다.
  **왜 못 걸렀나:** 결과 문구에 "(Bulbasaur, plain)" 을 하드코딩해 고정된 줄 알았다 — 같은 흐름의 표본 상점(`CompanionHeaderSamples.store`)은 `SplitMix(state: 9)` 를 넘기지만 셀프테스트 픽스처
  (`fixtureCompanion`)는 `rng` 를 안 넘겨 `SystemRandomNumberGenerator` 였다. 셀프테스트 3–4 프로세스 × 1/64 → 런당 약 6 %.
  **고침:** `CompanionHeaderSamples.PlainRolls`(SplitMix 의 수를 홀수로: 이로치는 roll % 64(부적 48) == 0 이라 몇 번째 수로 부화하든 일반), 체크가 `kind == .hatch(shiny: false)` 를 단언하고 실제 종류를 적는다.
  **부류 스윕:** 윈도 셀프테스트의 `CompanionStore(` 생성 — 부화·진화를 일으키는 것은 이 파일의 세 체크(celebrate/consumedOnce/liveUpdate)뿐이고 모두 이 픽스처를 쓴다. `HomeStores`·언어 체크는 부화하지 않는다.
  다른 `SystemRandomNumberGenerator`(Advanced/Team/Settings)는 무작위 코드·키 문자열이라 판정에 들어가지 않는다.
  **영구 캡처:** `CompanionHeaderModelTests.testThePlainHatchFixtureNeverRollsAShiny` — 10,000 수 중 이로치 0, 셀프테스트와 같은 구성의 부화가 일반. 결함 주입(`| 1` 제거)으로 308 개 이로치 → 실패 확인.
  **규칙:** 셀프테스트 픽스처가 결과("plain")를 이름에 달면 그 결과를 정하는 난수를 고정하고, 체크가 그 결과를 단언한다.

- **유휴 게이트 `popover-home-still-120s` 가 자정(UTC)을 걸쳐 측정됐다 — 하루 경계의 정상 새로고침이 "가만히" 창에 들어갔다.** 창 23:58:03 + 120 s, 앱 로그 00:00:00 `phase1 done total=0 … refresh done []`
  (`WindowsSystemEvents` 의 자정 타이머 → `UsageStore` 새로고침, 맥의 `NSCalendarDayChanged` 와 같은 한 번짜리). 새 스레드 14 개(user-initiated 4 개가 각 3.4–4.0 천만 사이클 = 파서), 메인 cs 53.
  통과 런의 같은 창: 메인 cs 4, 프로세스 113.5–132 /분, 18–20 만 사이클/s, 새 스레드 0. **제품 결함 아님.** **왜 못 걸렀나:** 창의 벽시계 시각은 런 시작 시각에 달렸고 러너는 UTC 라
  KST 오전 9 시 전후에 도는 런만 자정을 밟는다. **고침(워크플로, `ci/windows-app-split` 쪽):** 창 [시작, 시작+기동+길이+여유] 가 러너의 다음 자정을 품으면 자정+15 s 까지 기다렸다 시작한다.
  **부류 스윕:** 120 s 창 전부(closed/open/kit/home*/activity*/recap/companion*/sprite)가 같은 노출이고, 300 s normal 창은 새로고침 예산이 있어 견딘다.
  **규칙:** 유휴 창은 벽시계 경계(자정)를 걸치지 않게 놓는다 — 앱은 자정에 일을 한다.

- **`failCopy.secondUpdate.reasonLogged` 가 빈 내용으로 실패했다 — 피드 서버의 포트 파일을 "있다"만 보고 읽어 포트 0 을 얻었다.** 앱 로그 "the feed is the CI loopback http://127.0.0.1:0/releases/latest",
  `failCopySecond-requests.log` 0 줄, 포트 파일 내용은 54674. `Set-Content` 는 파일을 만든 뒤 쓴다 — 250 ms 폴링이 그 틈에 빈 파일을 읽었고 `[int]$null` 이 0 이 됐다. 앱은 60 s 동안 아무것도 받지 못했다.
  통과 런들은 12 개 피드 모두 실제 포트였다. **왜 못 걸렀나:** 틈이 µs–ms 라 거의 늘 통과했고, 실패 줄이 비어 원인이 안 보였다.
  **고침:** `Read-Port` — 내용이 양의 정수일 때만 포트로 읽는다. **부류 스윕:** `scripts/`·워크플로에서 다른 프로세스가 쓰는 파일을 존재만 보고 읽는 곳은 이 하나(`Wait-Until { Test-Path … }` 1 곳); 다른 `Set-Content` 는 같은 프로세스가 쓰고 읽는다.
  **영구 캡처:** 스크립트 시작의 `harness.emptyPortFileWaits` — 빈 포트 파일은 기다리고(옛 읽기는 0 을 냈다). **규칙:** 프로세스 사이 파일 전달은 존재가 아니라 내용으로 준비를 판정한다.
<!-- merged-head full run (fix/merged-head-full-run) end -->

## 윈도 플로팅 펫 (stage 7 Task 22)
<!-- stage 7 Task 22 (begin) -->
- **`pet.idle` 의 'hidden' 창이 펫을 끈 뒤에도 메인 cs 56·29·20(예산 6)을 셌다 — 펫이 아니라 픽스처가 깨웠다.** 두 원인이 겹쳤다. ① 펫을 끈 쓰기
  (`floatingPetEnabled = false`)의 디바운스 동기화가 창 안에 떨어졌다(debounce 1, safety 1). ② 표본 상점 `.hatched` 는 알에서 막 부화시키는데, **번들 앱에서**
  부화는 `ensureEggPrefetch` → `SpriteStore.shared.data` 3 개와 폼 이름(`PokemonNameClient.shared`)을 네트워크로 예열한다 — 러너의 번들 셀프테스트에서 그 완료가
  메인 스레드를 깨웠다. 같은 순서의 'still'(알, 부화 없음)은 메인 cs 0–1. 설치본 유휴 게이트(30 s 정착 뒤 120 s, run 44039613803)의 같은 창은 메인 cs 4 = manual-refresh 5.
  **왜 못 걸렀나:** 셀프테스트의 유휴 창은 `ui.kit.idle` 처럼 알려진 깨움(새로고침·동기화)만 예산에 더했고, 픽스처가 만드는 네트워크 일은 몰랐다. 맥 테스트는 번들 앱이 아니라 예열이 없다.
  **고침:** 창마다 앱 설정 동기화가 3 s 조용해질 때까지 기다리고(`waitStable { !WinDefaultsSync.isSyncPending }`), 새로고침이 걸린 창은 한 번 더 잰다. 유휴 창(셀프테스트·게이트
  프로브)은 막 부화한 표본 대신 키우는 중인 표본(`.midLevel`: 부화·예열 없음)을 쓴다.
  **부류 스윕:** 다른 유휴 프로브 — `--popover-companion-idle-probe` 는 `CompanionHeaderInput` 고정 입력이라 상점 부화가 없고, `--popover-sprite-idle-probe` 는 상점이 없다. `.hatched` 를
  쓰는 나머지(`companion.capture`·펫 캡처·클릭 체크)는 비용을 재지 않는다.
  **규칙:** 비용을 재는 창의 픽스처는 측정 전에 할 일을 다 끝낸 상태여야 한다 — 번들 앱의 부화는 네트워크 예열을 부른다.
- **`pet.hide`·`pet.resources` 가 재생 해제(`playback.release()`)를 빼도 통과했다 — 창이 사라지면 시계가 다음 틱에 스스로 서기 때문이다.** 결함 주입 런 44034871723 에서 15 개 중
  13 개 체크가 각자의 결함으로 실패했고 이 둘만 초록이었다. **왜 못 걸렀나:** "숨긴 뒤 시계가 무장돼 있지 않다"를 0.3 s 기다린 뒤 봤다 — 0.4 s 주기의 다음 틱이 `shouldTick`(창 없음)에서
  스스로 꺼진 뒤였다. 해제가 빠져도 프레임·디코드 캐시는 창 객체가 죽을 때까지 남는다. **고침:** 창이 사라지는 그 순간 재생이 `released` 이고 시계가 없고 프레임 집합이 0 인지 본다.
  **부류 스윕:** 팝오버의 `companion.clockStops` 는 닫은 뒤 시계만이 아니라 `playback.released`·프레임 집합 0·모델 0 을 본다(이 구멍 없음). 다른 펫 체크는 시계 정지를 보지 않는다. **영구 캡처:** 바뀐 두 체크 +
  결함 주입 런(release 제거) — 보고서에 run 번호. **규칙:** "멈췄다"는 기다린 뒤가 아니라 그 일을 하는 코드가 끝난 즉시 본다 — 스스로 서는 시계는 해제 누락을 가린다.
- **(리뷰 I1) 펫의 유휴 비용을 게이트 예산으로 재는 곳이 없었다 — `--pet-idle-probe` 는 어떤 워크플로도 부르지 않는 죽은 코드였고, `pet.idle` 은 조용해지지 않은 'hidden' 을
  통과시켰다.** 게이트 창은 스크래치 런에서만 재고 리드에게 "배선해 달라"고 넘겼는데 배선 전에 손을 뗐다(`$IdleShardOf` 16 개, 워크플로가 개수를 단언). 셀프테스트 쪽은 8 s 창에
  메인 cs 6(= 분당 45, 닫힌 앱 예산의 7.5 배)·메인만·최대 3 창 중 최선이라, 주기 8 s 이상이거나 0.75 Hz 미만인 깨움은 구조적으로 못 본다(run 44068394132 'hidden' [11, 4] 통과).
  **왜 못 걸렀나:** 잡음(동기화·러너) 때문에 판정을 계속 느슨하게 했고, 느슨해진 만큼을 게이트가 메운다고 가정했지만 게이트에 창이 없었다. **고침:** 게이트에 `pet-still/hidden-120s`
  (닫힌 앱 예산)·`pet-animated-120s`(측정 근거 예산, "Balanced" 의 프레임 깨움보다 낮게)를 샤드마다 하나씩 넣고, 프로브 로그 줄로 무엇을 쟀는지 확인한다. `pet.idle` 은 한 하네스를
  디스플레이 상태로 보이고 숨겨(설정 쓰기 없음) 'hidden' 을 같은 프로세스의 'still' 에 대해 한 창으로 판정(메인·프로세스 cs·사이클)하고, 펫 클래스 창·재생·시계가 남지 않았는지 본다.
  **부류 스윕:** 다른 `--*-idle-probe` 는 모두 `idle-gate.ps1` 에 있다(kit·sprite·popover·home·activity·recap·companion). **영구 캡처:** 샤드 표 + 워크플로의 개수 단언(19) + 결함 주입 런
  (1 Hz 타이머·숨은 창의 10 s `SetTimer`, 보고서에 run 번호). **규칙:** 측정 프로브를 만들면 같은 PR 에서 게이트에 건다 — 배선 안 된 프로브는 아무것도 지키지 않는다.
- **(리뷰 I2) `WM_DPICHANGED` 가 제안 사각형을 버리고 왼쪽 아래를 고정한 채 크기만 바꿨다, 드래그 중에도.** 200 % 노트북과 100 % 모니터 경계에서 커지면 창 대부분이 다른 모니터로 넘어가
  다시 작아지는 진동이 끝없이 가능하고, 드래그 중에는 다음 `WM_MOUSEMOVE` 가 `originAtDown` 기준으로 놓아 잡은 점이 펫 밖으로 튄다. **왜 못 걸렀나:** `pet.dpi` 는 lParam 0 으로 보냈고
  눌린 포인터가 없었다 — 단일 모니터 러너에서 트리거(혼합 DPI 경계, 드래그 중 변경)가 없다. **고침:** 공유 규칙 `FloatingPetDPIChange`(맥 테스트: 경계 진동 재현, 드래그 중 보류)
  — 드래그 중엔 크기 유지·놓을 때 적용, 그 외엔 lParam 사각형, 창 자신의 `UpdateLayeredWindow` 안에서 온 변경은 무시. `pet.dpi` 가 실제 사각형과 눌린 포인터로 보낸다.
  **부류 스윕:** 광장 창은 제안 사각형을 쓴다(`WinPlazaWindow`), 팝오버는 트레이 기준으로 다시 놓여 드래그가 없다. **사용자 PC:** 혼합 DPI 두 모니터에서 확인.
- **(리뷰 I3) 펫의 우클릭 메뉴가 전경을 숨은 싱크로 가져가고 돌려주지 않았다.** Escape·뒤로 보기·끄기 뒤 사용자의 앱이 비활성인 채 타이핑이 사라진다. **왜 못 걸렀나:** `pet.menu` 는
  항목과 동작만 봤고, `pet.noActivate` 는 클릭·드래그만 봤다(메뉴는 `SetForegroundWindow(owner)` 를 부른다). **고침:** 메뉴 전 전경 창을 기억하고, 열기(팝오버가 가져감)가 아니면
  싱크가 아직 전경일 때 되돌린다(팝오버 자신에게는 안 돌려준다 — 맥의 transient 팝오버는 바깥 클릭에 닫힌다). `pet.menu` 가 Escape·뒤로 보기·끄기 뒤 프로브의 전경·포커스를 본다.
  **부류 스윕:** `WinPopupMenu.run` 호출부 — 트레이(아이콘 클릭이 이미 작업 표시줄에 전경을 줬다), 팝오버 안 메뉴(팝오버가 전경)는 같은 구멍이 없다.
- **(리뷰 I4) 잠금 화면에서 만든 펫 창이 잠금 뒤에서 움직였다.** `locked` 가 false 로 시작하고 창마다 등록한 `WM_WTSSESSION_CHANGE` 로만 바뀐다 — Win+L → 화면 꺼짐 → 잠금 화면에서
  마우스 → `onScreensWake` → 새 창 → 시계. **왜 못 걸렀나:** 잠금 체크는 이미 있는 창에 메시지를 보냈다. **고침:** 창을 만들 때 `WTSQuerySessionInformationW(WTSSessionInfoEx)` 의
  `SessionFlags` 로 잠금을 읽는다(`ptb_session_state`), `pet.animation` 이 잠긴 채 만든 창(FIXTURE 상태)과 러너의 실제 읽기를 본다. **부류 스윕:** 같은 패턴 `WinPlazaVisibility`·
  `WinPopover` 는 사용자 동작으로만 창이 생겨 잠금 화면에서 만들어질 수 없다. 사용자 동작 없이 창을 만드는 곳은 펫뿐.
- **(리뷰 I5) 셀프테스트 스크립트의 한도(1200 s)가 단계의 `timeout-minutes: 20` 과 같아 Actions 가 1 초 먼저 단계를 죽여 "checks so far" 덤프가 안 나온다; 설치본 단계 25 분은 13.5 분짜리
  재시도를 담지 못한다.** **왜 못 걸렀나:** 스크립트 한도를 올리며 호출 단계를 같이 보지 않았다. **고침:** 번들 단계 25 분(플레이크 루프 55 > 3000 s), 설치본 45 분(두 번 + 여유)·잡 70 분,
  낡은 "about 6 min" 주석 교체, `pet.idle` 은 최악 ~5 분 → ~45 s. **규칙:** 스크립트 한도를 바꾸면 그 스크립트를 부르는 모든 단계의 한도를 같이 본다(스크립트 주석에 적었다).
- **(리뷰 M7·M8·M9·M11) 작은 것들.** M7: 지연 닫힘 중 팝오버는 `HWND_NOTOPMOST` 인데 펫을 그 뒤에 넣어 최상위 띠에서 빠질 수 있었다 → 팝오버가 `WS_EX_TOPMOST` 일 때만 그 뒤.
  M8: 축척 프레임 캐시가 48 MB 를 넘으면 통째로 비우고 다시 채워 384 DIP·200 % 긴 GIF 는 매 프레임 다시 축척했다 → 차면 앞 프레임들을 유지하고 나머지만 그때그때(공유
  `FloatingPetScaledFrames`, 맥 테스트). 부류 스윕: `WinSpriteAnimator` 의 프레임 캐시는 예산 없이 슬롯 크기(≤ 96 DIP)로 묶여 비우기·재채움이 없다. M9: 새 창이 스프라이트가 오기 전에
  🥚 를 DirectWrite 로 그렸다(아무도 못 보는 그림) → 첫 로드나 `revealDelay` 까지 그리지 않는다. M11: 디스플레이 변경의 `place()` 가 저장 위치를 덮어써 홈 모니터가 잠시 빠지면
  기본 모서리가 저장돼 돌아오지 않았다 → 사용자 드래그와 첫 기본 배치만 저장(맥은 대체 모서리를 저장한다: 인벤토리 F1 의 차이). `pet.clamp` 가 모니터 제거·복귀(실제
  `WM_SETTINGCHANGE(SPI_SETWORKAREA)`)로 집에 돌아오는지 본다. M10: 체크가 하네스 클로저를 바꾼 뒤 시드 메서드를 불렀다 → 실제 `WM_SETTINGCHANGE`·`WM_POWERBROADCAST` 를 보낸다.
- **펫 메뉴 뒤 전경 되돌리기(I3)가 활성화 허용 지점 밖(`WinFloatingPet.swift`)에서 `SetForegroundWindow` 를 불러 `WindowsSeamScanTests.testOnlyTheAllowedSitesActivateWindowsOfOurs`
  가 랜딩 브랜치에서 실패했다.** **왜 못 걸렀나:** 맥 확인을 `FloatingPet|PopoverPet|PopoverParity|…` 필터로만 돌려 `ScanTests` 가 빠졌다 — 윈도 코드의 규칙 스캔은
  이름에 기능명이 없다. **고침:** 되돌리기를 메뉴 실행기 `WinPopupMenu.run`(이미 허용된 지점)의 선택형 단계(`giveBack`)로 옮겼다 — 목록을 넓히지 않았다. 새 스캔 테스트가 그 함수의 활성화가
  "메뉴 주인"과 "메뉴 전에 전경이던 창(`previous`)" 둘뿐이고 그 가드가 있음을 고정한다(잘못된 대상·가드 제거 주입으로 실패 확인). **규칙:** 윈도 코드를 바꾼 맥 확인은
  `ScanTests|Popover|Pet|Settings|TrayMenu|AppWiring|HomeModel` 전체 세트로 돌린다.
- **(테스트 공백) 앞선 체크의 실제 클릭이 포인터를 다음 비용 창의 창 자리에 남겼다.** `pet.noActivate`·`pet.clickActions` 의 실제 클릭 자리가 `pet.idle` 펫 자리와 같아, 펫을 숨기면 포인터
  아래가 러너의 터미널 창(`CASCADIA_HOSTING_WINDOW_CLASS`)으로 바뀌며 번들 셀프테스트에서만 메인 스레드가 8 s 에 ~10 번 깼다(런 44049375908·44068394132·44093544046 실패, 설치본은 0).
  포인터를 우리 창이 없는 곳(데스크톱)에 둔 뒤엔 2 번, 꺼낸 메시지 없음(런 44107060600). **규칙:** 창을 보이고 숨기며 비용을 재는 체크는 먼저 포인터를 치운다(CI 에서만).
- **펫을 눌렀을 때 열린 팝오버를 누르는 순간 닫았더니 알 기도 클릭이 사라졌다(사용자 결정 2026-11-18 구현, 런 44129424988 `pet.clickActions`: prayed=false).** 활성 팝오버를 닫으면
  윈도가 전경을 다른 창(러너의 터미널)으로 넘기고, 버튼이 눌린 채 전경 스레드가 바뀌면 펫의 마우스 캡처가 끝나 놓기(`WM_LBUTTONUP`)가 펫에 오지 않는다 — 클릭도 드래그도 잃는다.
  **왜 못 걸렀나:** 맥 테스트는 "누름 → 닫힘 → 클릭"을 순서만으로 모델링했다(맥의 transient 닫힘은 이벤트 추적을 끊지 않는다). 윈도 체크가 실제 입력으로 잡았다(드래그는 이동량을 안 봐서 놓쳤다).
  **고침:** 누름에서 닫을지만 정하고 실제 닫기는 누름이 끝날 때(`buttonUp`·`captureLost`), 클릭이 행동하기 전에. `pet.clickActions` 의 드래그는 끝까지 움직였는지도 본다.
  **부류 스윕:** 버튼이 눌린 채 창을 닫거나 활성화를 바꾸는 다른 곳 — 펫 메뉴는 `WM_CONTEXTMENU`(놓은 뒤), 팝오버·광장의 자체 클릭은 자기 창 안이라 해당 없음.
  **규칙:** 캡처 중(버튼 눌림)에는 전경을 옮기는 일(활성 창 닫기·활성화)을 하지 않는다 — 놓을 때로 미룬다.
- **(테스트 공백) `pet.idle` 의 'hidden' 이 still·animated 를 귀속 판정으로 바꾼 뒤에도 같은 프로세스 cs 비교로 남아 windows-port 에서 실패했다(push 런 44200348337, 번들 셀프테스트:
  still 메인 cs 0, hidden 7 > 0+3, 남은 것 없음·재생 해제).** 직접원인: 셀프테스트 프로세스의 배경 깨움(펫과 무관). **왜 못 걸렀나:** still·animated 를 고칠 때(리드 결정 2026-11-18)
  같은 함수의 세 번째 창 'hidden' 은 "still 과 같은 방법으로 같은 프로세스에서 쟀으니 배경이 상쇄된다"고 보고 남겼다 — 두 창의 배경 깨움은 서로 독립이라 상쇄되지 않는다. 그 브랜치의
  실행들에선 배경이 조용해 통과했다. **고침:** hidden 도 남은 것(펫 클래스 창 0, 우리 창 수 그대로, 재생 해제·시계 없음)과 잰 창 안의 펫 일(틱·그림·펫 클래스 메시지 0, 이후 무장 없음)로
  판정하고 cs·사이클은 보고만 한다. **부류 스윕:** `pet.*` 와 펫 확장 체크(`pet.bubble`…`pet.extrasIdle`)에서 프로세스 cs·사이클로 판정하는 곳 전수 — 남은 것 없음(가게 로드 대기의
  2 s cs 는 판정이 아니라 기다림). 비용 판정은 게이트 창(`pet-still/hidden/animated-120s`, 펫 확장의 `pet-bubble-120s`·`pet-working-120s`)만 한다. **규칙:** 셀프테스트 프로세스 안의
  비용 체크는 귀속(그 기능 자신의 타이머·틱·그림·메시지)으로 판정하고 문맥 전환·사이클은 보고만 한다 — 같은 프로세스의 두 창을 서로 비교하는 것도 판정이 아니다.
- **(사용자 PC, kit 10) 부화한 플로팅 펫이 움직이지 않았다 — 첫 GIF 받기가 실패하면 그 세션 내내 정지 그림이었다.** 공유 `PopoverSpriteModel.show`(펫·팝오버 스프라이트)는
  `fetcher.animated` 를 한 번만 묻고, 비면 정지 PNG 로 떨어진 뒤 같은 대상인 동안 다시 묻지 않았다. 맥의 `SpriteLoader.recoveringAnimationFrames` 는 정지 그림을 보이고 2 s 부터
  두 배씩 30 s 까지, 횟수 제한 없이 GIF 를 다시 받는다. 새 설치(GIF 파일 없음, 트레이·팝오버가 PNG 는 받아 둠)에서 로그인 직후 네트워크가 아직이거나 한 번 실패하면 재현된다.
  **왜 못 걸렀나:** ① 쌍둥이 핀(`SpriteView.body` → `PopoverSpriteModel.show`)은 맥 본문만 해시했고, 본문이 부르는 `recoveringAnimationFrames` 의 재시도 의미는 어느 행도
  지키지 않았다 — 쌍둥이를 다시 지을 때 호출한 함수의 동작이 빠졌다. ② 펫·팝오버 체크는 전부 FIXTURE 폴더(GIF 가 이미 있음)나 픽스처 페처를 써서 내려받기 실패 경로를 한 번도 밟지
  않았다. ③ 펫이 왜 정지인지 로그에 아무것도 남지 않아 사용자 로그로 원인을 볼 수 없었다. **고침:** 공유 모델에 맥의 재시도 고리(정지 그림 한 번, 2→30 s, #1-649 만, 대상이 바뀌거나
  해제되면 끝)를 옮기고, `recoveringAnimationFrames` 핀 행을 더했다. 펫은 움직임/정지 상태와 그 입력(프레임 수, GIF 요청 횟수, 절전 플래그·AC, 시계, 표시·잠금·연결)을 바뀔 때만 한 줄
  로그로 남긴다. **회귀 테스트:** 공유 `PopoverSpriteModelTests`(첫 요청 실패 → 2 s·4 s 뒤 프레임, 30 s 상한, #700 은 묻지 않음, 대상 변경이 끝냄, 늦게 온 GIF 가 시계를 켬)와
  맥 `PopoverSpriteRetryTwinTests+Mac`(맥 함수와 대기 순서가 같음); 단일 시도로 되돌리는 결함 주입에 다섯이 실패함을 확인. 윈도 `pet.lateGIF` 는 실제 저장소 기반 페처
  (`PlazaStoreSpriteFetcher`) 위에서 첫 GIF 읽기를 실패시켜, 정지 → 2 s 뒤 움직임과 로그 두 줄을 본다. **부류 스윕:** 맥이 재시도하는데 쌍둥이가 한 번만 하는 곳 — 같은 모델을 쓰는
  팝오버 스프라이트(동반자 헤더·도감 상세·빈 상태·가방)가 이 고침으로 함께 고쳐졌다. 뒷모습 GIF 의 일시 실패는 맥은 뒷모습을 다시 묻고 윈도는 앞모습으로 대신한다(기존 차이, 이번 범위 밖).
  **규칙:** 맥 본문을 핀으로 묶을 때, 본문이 부르는 앱 함수의 재시도·타이머·폴백 의미도 같은 행이나 별도 핀 행으로 묶는다.
  같은 고침에서: 재시도의 대기와 요청은 메인 스레드 밖에서 돈다(대기 하나씩, 실패한 요청마다 메인 스레드를 깨우지 않고 GIF 가 왔을 때 한 번만) — 정지 펫 게이트 창의 메인 예산
  (6/분)이 30 s 재시도로 넘치지 않게. 그리고 펫을 만들 때의 잠금 판정을 SessionFlags 하나에 맡기지 않는다: LOCK(0) 이면서 입력 데스크톱이 사용자의 것이 아닐 때만 잠김(실제 잠금
  화면은 둘 다 잠김이라 그 뒤에서 움직이지 않는다), 원값은 새 로그 줄에 남긴다. **테스트 공백(사용자 PC):** CI 의 어떤 셀프테스트·게이트 창도 펫·팝오버 스프라이트를 앱 자신의
  `SpriteStore`(실제 내려받기 → 디스크 → 디코드)로 돌리지 않는다 — 전부 픽스처 페처나 FIXTURE 폴더다. 그 경로는 진단 브랜치의 실제 네트워크 프로브로만 확인했다.
  **(이어서, 사용자 셀프테스트 kit 10)** 그 PC 에서 시계·세션·"애니메이션 표시"·FIXTURE GIF 재생은 모두 정상이었다. 실제 실행 경로(`PlatformPlaza.spriteFetcher()` → 같은
  `SpriteStore` → `PlazaStoreSpriteFetcher.loadFrames` → 공유 모델)를 줄 단위로 읽고 광장(같은 저장소·같은 페처 종류·같은 디코더)과 비교했지만 디스크에 `132-a.gif` 가 있을 때 정지
  그림이 되는 단계를 코드에서 증명하지 못했다. 그래서 다음 키트의 로그가 결정한다: 로더는 그림·답마다 한 번(프로세스당) 시도한 변형별 파일 이름·바이트·디코드 프레임 수를, 팝오버
  슬롯은 상태가 바뀔 때 프레임 수·로딩·요청한 animated·재생·GIF 요청 횟수·"애니메이션 표시"·active·보임·디스플레이 꺼짐·시계를, 틱이 시계를 멈출 때는 그 이유(보임·디스플레이)를
  남긴다(펫은 위의 상태 줄). **규칙:** 실제 경로가 CI 에서 한 번도 돌지 않는 입력(앱의 저장소·전원·디스플레이 상태)은 그 값과 결과를 상태가 바뀔 때 로그에 남긴다.
- **(사용자 PC, kit 10) 사용자가 돌린 셀프테스트가 점검용 설정 키 네 개(`ptb.selftest.debounce/exit/close/endsession.*`)를 남겼다(`defaults.cleanup` 실패).** TEAM.md 는 "점검용
  설정은 끝나면 지운다"고 약속한다. 키는 자식 프로세스가 셀프테스트 설정 묶음 파일에 썼고, 부모는 `removeObject` + 동기화로 지웠다. corelibs CoreFoundation 의 설정 도메인은 메모리
  사본에 없는 키의 삭제를 아무 일도 아닌 것으로 무시하고(`writeXMLValue`: "the key is not present AND value is NULL, do nothing"), 파일은 동기화 때만 다시 읽는다 — 부모가 마지막으로
  동기화한 뒤 자식이 쓴 키는 삭제가 닿지 않는다. **왜 못 걸렀나:** CI 에서는 그 사이에 동기화(30 s 안전망 등)가 끼어 사본이 새로 읽혀 통과했다 — 체크가 트리거(동기화 없이 바로
  삭제)를 만들지 않고 타이밍에 기댔다. 또 CI 는 실행마다 새 상태 폴더(새 설정 묶음)라 남은 키가 다음 실행에 보이지 않는다; 사용자 PC 는 `PTB_STATE_DIR` 이 없어 고정 묶음
  `ptb.team.default.settings` 를 계속 쓴다. **고침:** `WindowsSelftest.removeChildKeys` — 먼저 동기화(자식이 쓴 것을 읽어 옴), 지우고, 다시 동기화. **부류 스윕:** 부모가 자식이 쓴
  키를 지우는 곳 전수 — 기본값 묶음(`defaults.*`·`exit.*`), `modalPump.exitInMenu`(`ptb.selftest.menuexit.*`), `settings.dialogExitProcess`(`ptb.selftest.dialogexit.*`) 셋 다
  고쳤다; 나머지 삭제는 같은 프로세스가 쓴 키라 해당 없음. **회귀 테스트:** `defaults.cleanupStale` — 부모가 동기화한 뒤 자식이 쓴 키를 평범한 삭제로 지우면 남는지(트리거 도달,
  동기화가 끼면 판정 안 함)와, 같은 조건의 다음 키를 `removeChildKeys` 가 지우는지 본다. **규칙:** 다른 프로세스가 쓴 설정 키는 지우기 전에 이 프로세스가 동기화해 읽어 온다.
<!-- stage 7 Task 22 (end) -->

## 윈도 셀프테스트의 시스템 설정 변경 (2026-11-17)

- **셀프테스트는 실제 시스템 설정을 바꾸지 않는다 — 특히 설정이 일으키는 연쇄(테마)를.** `ui.highContrast.system` 이
  러너의 `SPI_SETHIGHCONTRAST` 를 켰다가 껐는데, 윈도는 고대비를 켜면 테마를 적용하고 끌 때 다른 개인화 값
  (앱 라이트/다크 모드 등)을 원래대로 돌려놓지 않는다. 그 뒤 만들어진 키트 창은 레지스트리를 읽어 어두운 모습으로
  열렸다가 늦게 도착한 `WM_SETTINGCHANGE` 로 밝게 다시 만들어졌고, 스프라이트 페이지의 애니메이터는 옛 객체가 되어
  `companion.clockStops` / `companion.spriteFrames` 가 실패했다(시계 미작동, 두 캡처가 336×220 px 전체로 다름).
  - 직접원인: 검사가 되돌린 것은 고대비 플래그뿐이고, 그 부작용으로 바뀐 다른 시스템 값은 되돌리지 않았다.
  - **왜 못 걸렀나:** 그 브랜치의 CI 실행은 모두 `PTB_SELFTEST_APPEARANCE`(어두움·고대비 시뮬레이션)를 켠 캡처 실행이었다.
    그 환경변수는 레지스트리 읽기를 우회하므로, 레지스트리가 바뀌어도 아무 창에도 영향이 없었다. 기본(밝음) 환경 실행이
    한 번도 없었고, 하필 그 경로에서만 터지는 결함이었다. 검사 자신의 `restored=true` 는 고대비 플래그만 본 값이었다.
  - 부류 스윕: 셀프테스트의 `SystemParametersInfo`(SPI_SET…) / 레지스트리 쓰기를 전수 grep — 이 검사 외에는 없다
    (이 검사는 제거). 시스템 값을 바꿔야 하는 검사를 만들면 바꾼 값 *전부*(연쇄 포함)를 저장·복원하거나, 주입으로 대체한다.
  - 영구 캡처: 실제 플립 검사를 없애고 `ui.highContrast`(컨텍스트에 주입)만 남겼다. 환경 의존 경로(시뮬레이션 변수)를
    쓴 실행만으로 머지하지 않는다 — 기본 환경의 `windows-app` 실행 한 번이 필요하다.
  - **정정 (2026-11-24, 윈도 감사 F1):** 이 검사는 2026-11-19 에 `8bcbf2ab`(어두운 팝업 메뉴)와 함께 `popover.darkMenu.highContrast` 로 되돌아왔다. 주입한 판정(`popover.darkMenu.mode`)은 "고대비면 기본 모드를 고른다" 는 결정만 보고, 실제 테마에서 시스템이 그린 메뉴가 어둡게 되지 않는다는 *픽셀*은 볼 수 없었기 때문이다. 되돌린 쪽은 이 항목의 "바꾼 값 *전부* 복원" 을 읽지 않고 값 두 개만 복원했고, 게이트는 `11c9efe3` 이 "`CI` 가 있으면" 으로 걸었다. 지금은 Personalize 의 모든 값을 타입째 복원한다(아래 윈도 감사 항목).

- **윈도 앱이 파일 대화상자 근처에서 죽었다 — 메시지 훅이 `wParam` 을 `Int(_:)` 로 바꿨다 (#270 이후 `windows-port`, 셀프테스트 exit 0xC000041D, `settings.difficultyKeys` 직후).**
  **직접 원인:** 유휴 게이트의 깨움 추적(#270)이 펌프가 꺼내는 *모든* 메시지에 대해 `WakeTrace.message(message, wParam: Int(m.pointee.wParam))` 를 불렀다. `WPARAM` 은 부호 없는 64비트라 셸의 파일 대화상자가 보내는 2^63 이상 값에서 `Int(_:)` 가 트랩한다("Not enough bits to represent the passed value"). 변환은 호출 지점에서 일어나므로 `PTB_WAKE_TRACE` 가 꺼져 있어도(모든 사용자 PC) 실행됐다 — 창 프로시저 안의 Swift 트랩은 0xC000041D(사용자 콜백 안 치명 예외)로 보인다.
  **왜 못 걸렀나:** #270 브랜치의 full 런은 통과했다(그 런의 대화상자 점검에서는 그런 메시지가 오지 않았거나 순서가 달랐다 — 확인 못 함). `windows-port` 와 합친 트리는 `windows.yml`(컴파일·단위 시험)만 돌리고 머지했는데, 그 워크플로는 셀프테스트를 돌리지 않는다. 메시지 경로를 건드리는 변경인데 "CI 변경"으로 분류해 앱 런을 생략했다(리드의 판단 실수).
  **부류 스윕:** `Platform/Windows/**` 의 `Int(wParam)`/`Int(m.pointee.wParam)` 전수 — `WinPopover`(세션 변경 코드), `WinControls`(가상 키)는 메시지별 작은 값이라 안전. `LPARAM` 은 부호 있는 64비트라 `Int(lParam)` 은 트랩하지 않는다.
  **후속(방어):** `WakeTrace.message(_:wParam:target:)` 가 `wParam` 을 `UInt` 로 받는다 — 호출부에 변환이 없다. 트리거 값(`UInt.max`, 2^63)은 `WakeTraceTests.testMessageAcceptsAnyWParamBits`.
  **고침:** `Int(truncatingIfNeeded:)`, 그리고 추적이 꺼져 있으면 호출 자체를 하지 않는다. **규칙:** 메시지 파라미터를 정수로 바꿀 땐 `truncatingIfNeeded`/`bitPattern` 만 쓴다. 메시지 펌프·훅·창 프로시저를 건드리는 변경은 이름이 무엇이든 *합친 트리*에서 앱 런(셀프테스트)을 돌린 뒤에만 머지한다.

<!-- idle blow-up (fix/windows-idle-blowup) begin -->
## 윈도 HTTP 이음매: 클라이언트 인증서 요청과 스레드 핸들 (run 44143290510, 2026-11-17)

- **윈도에서는 부화 base 인덱스를 GraphQL 로 한 번도 받지 못했다. 그 대신 돈 REST 649 회가 유휴 게이트 창 셋을 채웠고, 페치마다 스레드 핸들이 하나씩 남았다.**
  **증상:** `windows-port` 2e1397c3 의 full run 44143290510 에서 유휴 게이트 shard 3 이 세 창 연달아 실패했다. `popover-home-still-120s` 는 67.4 M 사이클/s(예산 450 k),
  10,673 cs/분(예산 250), 핸들 669→1173(+504, 예산 +10). bars 는 52.6 M·+358, heatmap 은 44.0 M·+142. 주 스레드는 조용했고(cs 4) 일한 것은
  `com.apple.root.user-initiated-qos` 넷과 스레드 풀(`ntdll.dll+0x845d0`)이었다. 바로 다음 창 recap 은 정상(227 k·117 cs/분). 같은 시각 다른 브랜치의 run 44144033804 는
  shard 1·2 가 같은 모양으로 실패했다.
  **무엇이 돌았나(앱 로그):** 기동할 때마다 `base index (GraphQL) failed, no cache — REST build triggered … WinHttpSendRequest failed: WinHTTP error 12044` 뒤에
  `base index: building via REST` 가 찍혔다(`PokeAPIClient.buildBaseIndexViaREST`: pokemon-species 1–649 를 6 개씩, 페치마다 새 WinHTTP 세션·TLS·자기 스레드, 그리고 응답 JSON 디코드).
  끝나야만 `base-index.json` 을 쓰므로, 창이 닫히면 다음 기동이 1 번부터 다시 했다. 워밍업(60 s)·home·bars(각 150 s)는 모두 끝내지 못했고, heatmap 기동 48 s 째(창 18 s 째)에
  끝났다. recap 부터는 디스크에서 읽어 페치가 0 이었다. 초록 run 44112168764 도 같은 12044 를 맞았지만 같은 빌드가 10 s 만에(15:45:51→15:46:01) 워밍업 안에서 끝났다.
  실패한 run 의 shard 1·2 도 18:19 에 10 s 였다. 다른 것은 shard 3 러너에서 PokeAPI REST 가 5–15 배 느렸다는 것 하나다(150 s 에 약 640 페치, 대 10 s 에 649).
  코드·빌드(swift-crypto 3.15.1, 앱 2.5.634, 러너 이미지 20261103.298.1 동일)·게이트는 바뀌지 않았다.
  **원인 ①(12044):** graphql.pokeapi.co(Cloudflare)는 모든 클라이언트에 선택적 클라이언트 인증서를 요청한다(TLS CertificateRequest. `openssl s_client` 에
  "Acceptable client certificate CA names: … Cloudflare … Managed CA" 가 나온다). curl 과 맥 URLSession 은 인증서 없이 계속 진행해 200 을 받는다(curl 0.8 s).
  WinHTTP 는 거기서 `ERROR_WINHTTP_CLIENT_AUTH_CERT_NEEDED` 로 멈춘다. 문서에 나온 처리(`WINHTTP_OPTION_CLIENT_CERT_CONTEXT` = `WINHTTP_NO_CLIENT_CERT_CONTEXT` 를 걸고 다시 보내기)를
  이음매가 하지 않아 그대로 오류가 됐다. 그래서 `base-index.json` 이 없는 윈도 설치본은 늘 649 페치 REST 폴백을 탔다. 2026-11-15 100cc1de 에서 PokeAPI 가 이음매로 옮겨진 뒤의
  모든 키트(pc-5…pc-9)가 그렇다.
  **원인 ②(핸들):** 이음매는 페치마다 `Foundation.Thread` 를 시작했다. 윈도의 corelibs `Thread` 는 `_beginthreadex` 핸들을 `_thread` 에 담아 두고 닫지 않는다
  (swift-corelibs-foundation `Thread.swift`, swift-6.3.2-RELEASE·main 모두 `CloseHandle` 도 `deinit` 도 없다). 그래서 페치 하나마다 핸들 하나와 끝난 스레드의 커널 객체 하나가
  프로세스가 끝날 때까지 남았다. heatmap 창은 빌드가 끝난 뒤에도 핸들이 1080 에 머물렀다(정상은 약 430). 평소의 갱신 페치(상태 확인·한도 등)도 페치 수만큼 핸들을 쌓았다.
  **왜 못 걸렀나:** ① 이음매 테스트는 모두 루프백 HTTP 서버를 썼다. TLS 핸드셰이크를 거치는 서버가 없었고, CertificateRequest 를 보내는 서버는 더더욱 없었다. 넷버스트의
  'PokeAPI REST·GraphQL' 요청 모양도 루프백에서만 쟀다. 실제 호스트의 12044 는 매 run 의 앱 로그에 찍혀 있었지만, 실패 줄이 아니라 폴백 안내였기에 아무 검사도 보지 않았다.
  ② 유휴 게이트는 첫 실행의 네트워크 일을 60 s 워밍업이 흡수한다고 가정했다. 그 일의 양(649 페치)과 걸리는 시간은 외부 서버 속도에 달렸는데, 끝났는지 확인하지 않았다.
  빠른 러너에서는 그 일이 늘 숨었다. ③ 핸들 예산(+10)은 창 안에서 페치가 없으면 잡을 것이 없다. 정상 창에서는 기동 후 30 s 안에 페치가 끝나 그 핸들이 시작값에 들어갔다.
  스레드 하나가 핸들 하나를 남기는지 세는 테스트도 없었다.
  **고침:** `WinHTTPFetch.send` 는 송신이나 수신이 12044 로 멈추면 그 요청에 `WINHTTP_NO_CLIENT_CERT_CONTEXT` 를 걸고 한 번 다시 보낸다. 사용자의 인증서는 어떤 경우에도
  내지 않으며, 인증서를 반드시 요구하는 서버에서는 그대로 실패한다. 페치의 작업 스레드는 `WinDetachedThread` 로 만든다(`CreateThread` 직후 `CloseHandle`. 스레드는 계속 돈다).
  스레드를 만들지 못하면 호출자에게 바로 답하고 슬롯을 돌려준다(전에는 `Thread.start` 의 실패를 알 길이 없었다). 유휴 게이트 워밍업은
  `%LOCALAPPDATA%\PokeTokenBar\base-index.json` 이 생길 때까지(최대 +240 s) 앱을 열어 두고, 걸린 시간을 요약의 `warmup` 에 남긴다. `PTB_WAKE_TRACE=1` 에는 작업 스레드 쪽 귀속
  `fetch trace start/exit: started= ended= hosts= failures=` 를 더했고, 게이트는 창마다 그 차이를 `FETCHES <label>:` 줄과 `fetches` 항목으로 낸다.
  **가드(기계):** ① 셀프테스트 `net.clientCertificateOptional`: 실제 graphql.pokeapi.co 에 작은 POST 를 두 번 보낸다. 고친 경로는 HTTP 응답을 받아야 하고, 대조군
  (`clientCertificateAsBefore`)은 12044 로 멈춰야 '서버가 아직 요청한다' 는 것이 증명된다. 셀프테스트는 사용자 PC 와 릴리스 게이트에서도 돌므로 판정은
  `WindowsSelftest.classify`(순수 함수, `WindowsClientCertificateCheckTests`)가 한다: 실패는 '우리 답이 틀림'(인증서 요청에서 멈춤 -1206, 또는 대조군에 없던 실패)뿐이고,
  닿지 못함·시간 초과·호스트가 두 요청을 같은 식으로 실패함(PokéAPI 장애)·호스트가 더는 요청하지 않음은 `unverified (이유)` 로 통과한다. HTTP 상태는 5xx 라도
  핸드셰이크를 지났다는 뜻이라 검증으로 친다. 요청마다 타임아웃 10 s·전체 마감 15 s(세션의 `timeoutIntervalForResource`, `WinHTTPFetch` 가 그 시각에 호출자에게 답한다),
  두 요청을 동시에 보내므로 호스트가 무엇을 하든 약 15 s 안에 답이 나고 셀프테스트를 멈추지 않는다. ②
  `WindowsHTTPFetchTests.testTheFetchWorkersKeepNoHandleWhereFoundationThreadsKeepOneEach`: 한 세션에서 루프백 페치 100 회(세션 열기·닫기만 빼고 게이트·작업 스레드·
  타이머·연결·요청까지 전 경로) 뒤 핸들이 +20 미만이어야 하고, 대조군 `Thread` 100 개는 +90 이상, `WinDetachedThread` 100 개는 +10 미만이어야 한다. 실측(run 44166157252):
  한 세션 100 페치 +7, `Thread` +100, `WinDetachedThread` +0. 대조군이 실패하면 corelibs 가 고친 것이니 `WinDetachedThread` 를 걷어도 된다. ③ 게이트의 워밍업 대기와 `FETCHES` 줄.
  (정보: 페치마다 세션을 따로 열면(앱의 방식) 닫힌 세션 하나가 핸들 약 2 개를 45–60 s 동안 더 쥐고 있다가 WinHTTP 가 놓는다. 100 페치 기준(run 44168716060)으로
  시스템 프록시 경로는 45 s 까지 +200 이었다가 60 s 에 +47, 직접 경로는 60 s 에 +89·75 s 에 +74 였다. 누수가 아니라 늦은 해제이고, 스레드 몫과는 따로다.
  실패한 heatmap 창이 빌드가 끝난 뒤에도 페치당 약 1 개(스레드)만 남긴 것과 맞는다.)
  **스윕:** ① 같은 API 오용(윈도 Foundation 이 커널 핸들을 쥐고 닫지 않음): 출하 코드에서 `Thread` 를 시작하는 곳은 이음매(고침), `WinSocketLoop`(프로세스당 한 번이고 앱 종료 때만
  다시 만든다. 핸들 하나라 그대로 둔다), `WinUIDump`·`WindowsSelftest*`(셀프테스트 전용이라 그대로 둔다)다. corelibs `Process` 는 스레드 핸들을 바로 닫고, 프로세스 핸들은 `deinit` 에서
  닫는다(확인함). ② 같은 TLS 차이(서버의 CertificateRequest): 앱이 부르는 호스트 18 곳을 `openssl s_client` 로 확인했다. CertificateRequest 를 보내는 곳은 graphql.pokeapi.co 하나다.
  ③ 같은 모양의 첫 실행 일(끝나야 저장하고 기동마다 처음부터 다시 함): `buildBaseIndexViaREST` 하나뿐이다. 업스트림 소유인 `Core/` 라 바꾸지 않았다. 이제 GraphQL 이 윈도에서도 되므로
  REST 빌드는 GraphQL 장애 때만 돈다(맥과 같다). **알려진 한계(업스트림 소유 코드, 맥과 같음):** GraphQL 이 정말로 죽어 있으면(오프라인, PokéAPI 장애) 캐시가 없는 한
  부화가 있는 기동마다 REST 빌드가 1 번부터 다시 649 페치를 하고, 한 기동이 끝까지 가야 저장된다(오프라인이면 DNS 실패 649 회, 5xx 면 TLS 649 회와 닫힌 세션마다 1 분쯤
  남는 핸들 2 개). 그동안 부화는 막히지 않는다 — `chooseBaseViaREST` 가 무작위 id 를 최대 16 번 물어 base 를 고르고(가중치 없음), REST 도 안 되면 알을 유지하고 다음 틱에
  다시 한다. 기동을 넘어 잇거나 실패 라운드에서 멈추는 안(`feat/base-index-rest-resume`)은 맥 동작을 바꾸므로 사용자 결정을 기다린다. 이 한계 때문에 유휴 게이트는 PokéAPI 가
  느리면서 GraphQL 까지 죽은 드문 경우에는 여전히 측정 창에 REST 빌드가 들어갈 수 있다(워밍업은 최대 300 s 를 기다린 뒤 요약에 적고 계속한다. 셀프테스트는 #274 가
  `base-index.json` 을 미리 심는다).
  **사용자 PC:** 키트 pc-5…pc-9(모두 100cc1de 이후)는 두 결함을 다 가진다. ① `base-index.json` 이 없는 실행(첫 실행, 또는 빌드가 끝나기 전에 끈 다음 실행)마다 649 페치 REST
  빌드가 돈다. CPU 는 수 초를 쓰고, 핸들 약 650 개가 앱 종료까지 남는다. 끝나면 30 일 캐시로 남고, 그 뒤로는 오래된 캐시를 계속 쓴다. ② 모든 페치가 핸들을 하나씩 남긴다
  (120 s 마다 상태 확인·한도 몇 개 → 켜 둔 하루에 천 단위). 프로세스 한도(약 1,600 만)와는 거리가 멀지만, 작업 관리자의 핸들 수가 선형으로 자란다.
  **규칙:** 네트워크 이음매는 루프백만이 아니라 앱이 실제로 부르는 호스트와의 TLS 핸드셰이크로도 확인한다(셀프테스트에서, '실패' 와 '닿지 못함' 을 구분해서).
  윈도에서 작업마다 스레드를 만들 때는 `WinDetachedThread` 를 쓴다. 유휴 게이트의 워밍업은 첫 실행 일이 끝났다는 신호(파일)를 기다린다. 시간으로 끝났다고 가정하지 않는다.

- 이 브랜치의 full run 44157998092 에서 번들·설치 셀프테스트가 파일 대화상자 검사 중 같은 훅 트랩으로 죽었다(`PokeTokenBar.exe+0x7AA80F`, exe 의 DWARF 로
  `WinMessageHook.swift:56` "Not enough bits to represent the passed value"). 고침은 위 #272 항목(메시지 훅의 `Int(_:)`)의 것을 쓴다. 이 브랜치는 그 고침에 트리거 가드를 더한다: 셀프테스트
  `loop.highWParam` 이 wParam `UInt.max` 와 `1 << 63` 을 실제 펌프로 보낸다(고치기 전 코드에서는 이 검사에서 프로세스가 죽어 보고서가 남지 않는다. run 44166164011 에서 통과).
<!-- idle blow-up (fix/windows-idle-blowup) end -->

<!-- process shim kill (fix/windows-process-shim-kill) begin -->
## 윈도 프로세스 트리 종료: 재사용된 프로세스 id (windows.yml 44207854338, 2026-11-18)

- **`.cmd` shim 의 자식을 함께 끝내는 `PlatformCompat.terminate` 가 shim 과 무관한 프로세스까지 죽였다 — 테스트 프로세스 자신을 포함해서.**
  **증상:** `feat/windows-pet-extras` 의 `windows.yml` 44207854338 shard 4 의 마지막 청크가 `WindowsProcessTests.testTerminatingACmdShimEndsItsChild` 안에서 끝났다
  (1001 개 중 751 개 실행, 실패 0, 요약 줄 없이 `swift test` 종료 코드 1). 출력은 테스트 시작(00:55:31.021)에서 끊겼고, 그 뒤의 줄은 전부 00:56:03.6 에 한꺼번에 나왔다.
  **근거:** shim(cmd.exe)과 그 자식 PowerShell 은 corelibs `Process` 의 `bInheritHandles: true` 로 xctest 의 stdout 파이프를 물려받는다. 그래서 `swift test` 는 PowerShell 이
  나갈 때에야 EOF 를 봤고, 끊긴 뒤 32 s 는 PowerShell 의 기동과 `Start-Sleep 30` 을 그대로 다 쓴 시간이다. 즉 PowerShell 은 끝나지 않았고, xctest 는 그 전에 죽었다.
  **원인:** `terminate` 는 Toolhelp 스냅숏의 `th32ParentProcessID` 만으로 트리를 만들고, 찾은 것을 깊은 쪽부터 id 로 `TerminateProcess(…, 1)` 했다(3f8ddff6).
  윈도는 프로세스 id 를 재사용하고, `th32ParentProcessID` 는 *만들 때의* 부모 id 일 뿐이다. 그래서 만든 프로세스가 이미 끝나 그 id 가 shim(또는 그 자식)에게 다시 배정되면,
  훨씬 오래된 무관한 프로세스가 shim 의 '자식' 으로 보이고 함께 죽는다. 같은 규칙으로 옛 코드는 가짜 스냅숏에서 [현재 프로세스, 무관한 두 프로세스, 진짜 자식] 을 골랐다
  (`ProcessTreeSelectionTests` 결함 주입). PC 에서 대표적인 그런 프로세스는 explorer.exe 다(만든 userinit.exe 가 로그온 뒤 끝난다). 출하 코드에서는 `ProcessRunner` 가 Codex 한도
  갱신 때마다 codex(npm `.cmd` shim)를 이렇게 끝낸다.
  **러너 실측(임시 진단, windows.yml 44230921044·44228430972):** 테스트 프로세스의 조상(swift-test ← swift ← bash ×3 ← Runner.Worker ← Runner.Listener ← …)은 모두 살아
  있지만, 러너에는 만든 프로세스가 끝난 프로세스가 10 개 있었다 — wininit.exe·csrss.exe(만든 smss 인스턴스가 끝남), explorer.exe·winlogon.exe 등, 그리고 지금 단계의 파이프라인
  `tee.exe` 둘(포크한 bash 가 끝남). 옛 규칙으로 shim 이 그 끝난 id 하나를 받으면: wininit 의 것(712)이면 **132 개**를 끝내려 한다(svchost ×78, Runner·bash·swift-test 를 지나
  이 테스트 프로세스까지 — 깊은 쪽부터 끝내는 순서에서 **10 번째**, PowerShell 보다 앞). 이것이 44207854338 과 정확히 같은 모양이다(테스트 프로세스가 먼저 죽고 PowerShell 은
  30 s 를 다 잤다). explorer 의 것(5816)이면 explorer·dwm·winlogon·csrss 등 8 개, tee 의 것이면 그 단계의 로그 파이프. 새 규칙은 모든 경우 0 개다. 새 shim 이 방금 끝난 id 를
  받는 일은 실제로 일어난다 — 430 개 중 3 개가 우리가 막 끝낸 cmd 24 개의 id 를 받았다. PC 에서는 explorer 아래가 사용자가 띄운 앱 전부다(PokeTokenBar 자신 포함).
  **같은 함수의 둘째 결함:** 트리를 다 끝낸 뒤 corelibs `Process.terminate()` 를 불렀다. 그것은 `processHandle` 로 `TerminateProcess` 하는데, 그 핸들은 프로세스가 끝나면 corelibs 의
  관리 스레드가 닫는다(`Process.swift` `closeHandler`, 값은 그대로 남는다). 자식을 먼저 죽이면 shim 이 곧 끝나므로, 닫힌 핸들(다른 객체에 재배정되었을 수 있는 값)로 부를 수 있었다.
  이번 사고는 아니다(그랬다면 PowerShell 이 먼저 죽었다).
  **왜 못 걸렀나:** 테스트는 '자식이 끝났나' 만 봤고 '다른 것은 살아 있나' 는 보지 않았다. 재사용된 id 가 shim 에 걸리는 일은 러너의 프로세스 생성 순서에 달린 드문 경우라
  여러 번의 통과가 아무것도 증명하지 못했다. 테스트의 정리(`defer { forceKill(pid: child) }`)도 같은 부류였다 — 이미 끝난 자식의 id 를 다시 죽였다.
  **고침:** 고르는 규칙을 공용 순수 함수 `ProcessTreeSelection.descendants` 로 떼었다(`GetProcessTimes` 의 생성 시각). 루트는 스냅숏에서 현재 프로세스의 자식이고 우리보다
  오래되지 않아야 하며, 아니면 아무것도 고르지 않는다. 자식은 *자기가 적은 부모*보다 먼저 만들어지지 않았고(루트와 비교하지 않는다) 스냅숏 시각보다 뒤가 아닐 때만 자식이다.
  현재 프로세스는 시각을 묻기 전에 규칙으로 거른다(그래서 그 핸들을 열지도 않는다). 걸러진 프로세스 아래는 보지 않는다. `WinProcessTree.terminate(process)` 는 끝낼 모든 프로세스를,
  판단에 쓰는 스냅숏 *전에* 연 핸들로 붙잡는다(열린 핸들은 프로세스 객체를 붙잡아 두므로 그동안 id 가 다른 프로세스로 넘어갈 수 없고, 스냅숏의 그 id 줄은 그 프로세스의 것이다):
  (1) 어느 스냅숏보다 먼저 루트를 붙잡는다 — corelibs `processHandle` 을 `DuplicateHandle` 하고, 그 뒤에도 `process.isRunning` 이고 `GetProcessId(사본) == pid` 일 때만 쓴다.
  swift-corelibs-foundation 6.3.2 는 `isRunning = false` 를 쓴 *뒤에* 그 핸들을 닫으므로(`terminateRunLoop`), 복사 뒤에도 실행 중이면 복사한 값은 아직 그 핸들이었다.
  붙잡지 못하면(이미 끝났거나 corelibs 가 닫았다) 아무것도 끝내지 않는다. (2) 첫 스냅숏을 걸으며 후보를 연다. (3) 모두 연 뒤 둘째 스냅숏을 찍어, 이미 연 핸들의 생성 시각으로만
  같은 규칙을 다시 돌리고 그 결과만 그 핸들로 끝낸다. (4) 다 고르고 붙잡은 뒤 루트를 먼저, 붙잡은 핸들로만 끝낸다(corelibs 와 같은 코드 0xC000000F — 자식이 먼저 끝나면
  shim 이 제 코드로 먼저 나가는 일이 잦았다). 그다음 자손을 깊은 쪽부터. 반환값은 루트의 `TerminateProcess` 결과다.
  corelibs `terminate()` 는 윈도에서 부르지 않는다. `ProcessRunner` 가 시간 초과 때 2 s 뒤 id 로 하던 `forceKill` 은 `PlatformCompat.forceKillIfStillRunning` 으로 옮겨 윈도에서는
  하지 않는다(`TerminateProcess` 는 무시할 수 없고, 2 s 뒤의 id 는 다른 프로세스의 것일 수 있다). 맥은 둘 다 그대로다(`process.terminate()`, 2 s 뒤 실행 중이면 `SIGKILL`).
  테스트는 자식 핸들을 붙잡아 두고 그 핸들로 정리하며, PowerShell 기동을 60 s 까지 기다린다(15 s 를 넘긴 적이 있다, run 44168716060).
  **첫 고침(22b3474b)의 남은 틈(리뷰):** 스냅숏과 `OpenProcess` 사이에 끝나 재사용된 id 를 받아들였다 — 신원 확인이 스냅숏 *뒤에* 읽은 시각 상한(`time <= snapshotTime`)뿐이라,
  그 사이에 만들어진 프로세스가 통과했다. 루트에서는 흔하다: `ProcessRunner` 가 자식의 stdin 을 닫은 직후 terminate 하므로 shim 이 걷는 도중 끝나는 일이 잦고, 방금 끝난 id 는 곧
  다시 배정된다(위 실측: 430 개 중 3 개). 그래서 루트를 corelibs 핸들로 먼저 붙잡고, 둘째 스냅숏으로 다시 고른다. 상한은 남겼다 — 이제 할 일은 시계를 뒤로 돌린 경우를 좁히는 것이다.
  **받아들인 한계(코드 주석에도):** 생성 시각은 벽시계다. 시계를 뒤로 돌리면 대개 진짜 자식이 부모보다 오래되어 보여 놓친다(그 호출의 CLI 자식이 남는다). 드물게는 잘못 받아들인다:
  어떤 프로세스의 id 를 그 전 주인이 쓸 때 만든 무관한 프로세스가, 돌린 시계 때문에 새 주인보다 새것으로 보일 때(스냅숏 시각 상한이 그 창을 좁히지만 닫지는 못한다).
  같은 생성 시각(클록 틱 단위)은 순서와 관계없이 부모·자식으로 본다. 옛 코드와 새 코드가 모두 놓치는 것: 중간 프로세스가 끝나 사슬이 끊긴 자식, 걷는 도중(첫 스냅숏 뒤)
  만들어진 자식. 새 코드만 놓치는 것: 루트가 둘째 스냅숏 전에 끝난 경우(끝났지만 핸들로 붙잡힌 프로세스가 Toolhelp 스냅숏에 나오는지는 확인하지 않았다 — 나오지 않으면 그 아래를
  놓친다). 놓침은 잘못 끝내기보다 가벼운 실패로 본다.
  **후속(지금 하지 않음):** `process.run()` 직후 루트를 Job Object 에 넣으면 추측 없이 트리를 끝낼 수 있다. 단 corelibs 는 일시정지 상태로 만들지 않으므로 run 과 넣기 사이에 생긴
  자식은 빠지고, 루트가 이미 다른 job 안에 있을 때의 동작 등 따로 확인할 것이 있다.
  **가드(기계):** `ProcessTreeSelectionTests`(9, 맥·윈도 공용): 진짜 자식·손자는 깊은 쪽부터, 재사용된 id 를 부모로 적은 더 오래된 프로세스와 그 아래는 제외, 루트보다 새것이지만
  자기가 적은 부모보다 오래된 프로세스는 제외(950←200: 505 < 510), 열 수 없거나 스냅숏 뒤 시각인 것과 그 아래는 제외, 같은 틱의 자식은 포함, 현재 프로세스는 같은 틱이어도
  받지도 묻지도 않음, 루트가 스냅숏에 없거나·부모가 우리가 아니거나·우리보다 오래되면 아무것도 고르지 않음. 결함 주입 10 개가 각각 해당 테스트에서 실패한다: 부모 대신 루트의 시각과
  비교하면 950 테스트만 실패한다(첫 고침의 4 테스트는 모두 통과했다 — 리뷰 지적), 현재 프로세스 규칙을 빼면 [50, 200], 시각을 물은 뒤 거르면 물은 목록 [200, 50], 생성 시각
  규칙을 빼면 트리거 테스트가 [901, 900, 200]. `seen` 집합은 뺐다: 스냅숏은 프로세스당 한 줄이라 부모가 하나이고, 루트의 부모는 현재 프로세스이며 현재 프로세스는 받지 않으므로
  어떤 프로세스도 두 번 닿지 않는다 — 그것이 막는 입력이 없어 지키는 테스트를 만들 수 없었다. `WindowsProcessTests`: 실행 중인 shim 은 true 를 돌려주며 자식과 함께 끝나고,
  끝난 뒤에는 붙잡을 수 없어 false 다(아무것도 끝내지 않는다).
  **스윕:** id 로 프로세스를 끝내는 출하 코드는 `PlatformCompat.forceKill(pid:)` 하나였고, 윈도에서의 유일한 호출(`ProcessRunner` 시간 초과 2 s 뒤)은 없앴다(윈도 분기는 남았고
  호출부가 없다. 맥은 그대로). 셀프테스트 `WindowsSelftest.Helper.start` 는 `process.run()` 직후 id 로 `OpenProcess` 해 그 핸들로 나중에 끝낸다 — 같은 부류지만, corelibs 가 핸들을
  쥐고 있는 동안은 id 가 재사용될 수 없어 틈은 자식이 run 직후 그 몇 μs 안에 끝나고 corelibs 가 닫는 경우뿐이다. 셀프테스트 전용이라 고치지 않았다. Toolhelp 부모 id 를 걷는 곳은
  이 함수뿐(셀프테스트 둘은 이름으로 세기만 한다). corelibs `terminate()` 를 직접 부르는 `BinaryLocator`(`$SHELL`)·`UpdateChecker`(brew) 는 윈도에서 실행되지 않는다.
  **규칙:** 윈도에서 프로세스를 id 로 찾아 끝내지 않는다. 끝낼 프로세스는 판단에 쓰는 스냅숏 전에 연 핸들로 붙잡고 그 핸들로 끝내며, 부모 id 는 그 핸들에서 읽은 생성 시각으로
  확인한다. corelibs `Process` 의 프로세스는 `processHandle` 의 사본을 `isRunning` 으로 다시 확인한 뒤에만 쓴다.
<!-- process shim kill (fix/windows-process-shim-kill) end -->

## 셀프테스트가 살아 있는 파트에 다른 폭을 먹였다 (2026-11-18)

- **`home.activityHover` 가 날짜에 따라 실패했다 — 점검의 `point(of:)` 가 막대를 창 콘텐츠 폭(332)으로 찾으면서 살아 있는 파트의 폭(311)을 바꿨다.**
  `TrendBarsPart.size(width:)` 는 파트가 마지막으로 잰 폭을 저장하고 `date(at:)` 도 그 폭으로 배치한다. 점검은 332 로 "가장 높은 막대의 첫 픽셀"을 찾아 호버했고(첫 호버는 332 배치 위에서 맞았다),
  그 뒤 렌더가 호스트 폭 311 로 다시 재면서 같은 점이 이웃 열/틈이 됐다. 같은 열 +1 px 이동이 `selected=-` 로 선택을 잃어 다시 그렸다("re-rendered=true").
  **제품 결함 아님** — 카드 창은 `WS_EX_TRANSPARENT`(마우스 투과)이고 진단 줄의 `under=Button` 은 패널 항목 자신이다.
  - **왜 날짜에 따랐나:** 가장 높은 막대 = 오늘 − 6 일의 열. 열 위치가 날짜로 움직이고, 332 폭의 첫 픽셀이 311 폭의 같은 열 안(통과)인지 밖(실패)인지가 열마다 다르다. 11-11 은 안, 11-12 는 밖이었다.
  - **왜 못 걸렀나:** 통과하는 날이 대부분이었고 실패 줄이 "같은 열에서 다시 그렸다"뿐이라 위치 정보가 없었다. 첫 호버 `selected==target` 은 332 배치에서 맞아 폭 불일치를 가렸다.
  - **고침:** 점검이 파트 자신의 폭(`TrendBarsPart.width`, 읽기 전용으로 공개)으로 찾는다. 실패 줄에는 포인터·카드·항목 사각형과 선택·뷰 통계를 남긴다.
  - **부류 스윕:** 셀프테스트의 `size(width:)` 호출은 이 하나뿐(나머지는 호스트 경로). "오늘"을 시계에서 받는 픽스처(`ActivityFixtures`, Recap `series`, Home 의 `now`)는 날짜별 열 위치에만 의존하며 이 부류는 이 점검이 유일하다.
  - **영구 캡처:** `PopoverActivityTests.testAPointFoundAtThePartsOwnWidthStaysOnItsColumn` — 7월 1–14 일 모두에서 자기 폭의 점은 +1 px 에서 열을 지키고, 다른 폭의 점은 일부 날에 지키지 못한다(함정을 고정). **규칙:** 살아 있는 파트를 재는 점검은 파트의 현재 폭을 쓰고, `size(width:)` 로 폭을 바꾸지 않는다.

<!-- popover sprite shown (fix/windows-popover-sprite-shown) begin -->
- **(사용자 PC, kit 11 로그) 팝오버의 스프라이트(홈 헤더·도감 상세)가 하나도 움직이지 않았다 — 디코드는 됐고(`583-a.gif: 41885 bytes, 73 frames`) 첫 틱에서 시계가 멈췄다
  (`shown=false`, 45 초에 16 번, `shown=true` 는 한 줄도 없음).** 직접원인: `WinSpriteAnimator.isShown` 이 `GetParent` 로 올라갔다. `GetParent` 는 최상위 팝업에서 **owner** 를
  돌려주고, 팝오버의 owner 는 앱의 숨은 싱크(클라이언트 0x0)라 교차가 비어 모든 스프라이트가 "안 보임"이었다. 칠할 때마다 시계가 다시 켜지고 다음 틱에 꺼져, 그림은 첫 프레임에 멈췄다.
  **왜 못 걸렀나:** ① 스프라이트 시계 체크(`companion.spriteFrames`·`clockStops`)는 owner 없는 KitWindow 에서 돌았다 — 실제 팝오버의 창 구성(owner 있는 팝업)과 달랐다. ② 실제 팝오버를
  여는 체크들은 스프라이트 시계를 보지 않았고, 러너의 "애니메이션 표시"가 꺼져 있어 실제 팝오버에서는 시계가 켜질 일 자체가 없었다(정지 그림이 정상). ③ 칠할 때 다시 켜지는 동작이
  캡처를 정상으로 보이게 했다. **고침:** 부모 체인만(`WS_CHILD` 인 동안 `GetAncestor(GA_PARENT)`) 올라 최상위 창에서 멈춘다. 그리고 멈춘 시계가 칠하기 없이도 돌아오는 유일한 경우를
  더했다: 디스플레이가 깰 때(그때 윈도는 다시 칠하지 않는다), 꺼져 있는 동안 타이머 없이. 화면에 다시 나오는 뷰는 늘 칠해진다(창이 함께 다시 보임·스크롤 백·가림 해제; 팝오버를
  다시 열거나 페이지를 바꾸면 새 뷰를 만든다) — 그래서 그 경우는 칠하기가 시계를 다시 켠다. **부류 스윕:** `GetParent` 로 오르는 곳 — `WinScrollArea.reveal`
  (스크롤 영역을 찾을 뿐이라 owner 까지 가도 해 없음), `isShown`(고침). `isShown` 을 쓰는 동반자 헤더의 효과 시계·진화 라인 이동도 같은 고침으로 실제 팝오버에서 처음 돈다.
  **회귀 테스트:** `popover.spriteShown` — 앱 싱크가 owner 인 실제 `WinPopover` 를 트레이 위치에 열고(고정 GIF, 애니메이션 켬) 홈 헤더와 도감 상세가 보임·시계·틱·프레임 이동을 갖는지,
  홈 헤더를 짧게 만든 뷰포트에서 스크롤 아웃/백, 도감 상세가 든 창 숨김/다시 보임(뷰에는 `WM_SHOWWINDOW` 가 오지 않고 칠하기만 온다), 디스플레이 꺼짐/켜짐에서 멈췄다 스스로 돌아오는지 본다. 고치기 전 걷기(`GetParent`)를 옆에 찍어 트리거(여기서 false)를 보인다.
  (첫 판의 체크는 도감 상세를 스크롤해 판정했다가 실패했다 — 상세의 그려진 뷰가 탭 내용 전체라 80 px 뷰포트에도 늘 일부가 남는다. `isShown` 은 뷰 단위라 그런 뷰는 스프라이트 칸이
  스크롤로 나가도 시계가 돈다; 고치기 전과 같은 성질이고 이번 범위 밖.)
  **규칙:** 창 체인을 오를 때 `GetParent` 는 최상위 팝업의 owner 를 돌려준다 — 부모만 오를 땐 `WS_CHILD` 동안 `GetAncestor(GA_PARENT)`. 화면 상태 체크는 실제 창과 같은 소유 관계에서 돈다.
- **(같은 로그) 플로팅 펫은 kit 11 에서 움직였다(`41 frames at the 0.1 s floor`, `89 clock fires, 89 ticks` / 10 s).** kit 10(windows-port #280+#281)과 사이의 펫 경로 차이는 잠금 판정
  (SessionFlags 하나 → SessionFlags·입력 데스크톱), GIF 재시도, #283 확장(그리기 합성), 로그다. 이번 실행의 값으로 보면 kit 10 의 판정도 같았다(SessionFlags=0x1 이면 kit 10 도 잠기지
  않음, 첫 GIF 요청이 성공해 재시도가 일하지 않음, 절전 꺼짐, #283 은 시계·프레임 선택을 건드리지 않음). 그래서 이 실행에서 움직인 것을 그 코드 변경이 설명하지 못한다. kit 10 세션에는
  펫 로그가 없어(#285 에서 생김) 그때의 원인은 **증명되지 않았다** — kit 10 의 보고와 맞는 남은 설명은 그 세션들의 첫 GIF 요청 실패(kit 10 은 다시 묻지 않음)다.
<!-- popover sprite shown (fix/windows-popover-sprite-shown) end -->

<!-- agent link cold start (feat/windows-pet-link) begin -->
- **(CI, 라이트 런 44255743956) `link.coldStart`: 앱이 없을 때의 정상 링크가 0 으로 58 ms 에 끝나고 깨끗한 시작이 하나도 없었다.** 직접원인: GitHub 의 Windows 러너는 관리자·UAC 꺼짐으로
  돌아 토큰이 승격돼 있고(이 체크의 새 메모 `this runner's token elevated=` 가 보인다), 링크 시작은 설계대로 승격 분기(아무것도 켜지 않음)로 갔다. **왜 못 걸렀나:** ① 체크가 러너의
  토큰을 확인하지 않고 승격되지 않은 여는 쪽을 가정했다 — 결정 표의 단위 테스트는 두 분기를 다 덮었지만 셀프테스트는 러너에서 도달할 수 없는 분기를 기대했다. ② 깨끗한 시작은
  결과를 어디에도 남기지 않아(링크 시작은 아무것도 쓰지 않는다는 설계) 실패한 CreateProcessW·승격 포기·성공을 로그로 구별할 수 없었다. ③ 그 브랜치의 첫 라이트 런이 릴리스
  빌드 오류로 셀프테스트까지 가지 못해 한 번 늦게 드러났다. **고침:** 결정에 `droppedElevated` 를 따로 두고, 깨끗한 시작의 세 결과(pid·CreateProcessW 오류·승격 포기)를 각각 한 줄로
  남긴다(드문 시작이고 사람이 그 결과를 본다). 체크는 러너의 승격에 따라 기대를 고르고(승격: 포기 줄과 시작 없음, 아님: 로그의 pid 로 정확히 그 프로세스를 멈춘다), 깨끗한 시작
  자체(`startClean(suspended: true)`: 같은 CreateProcessW·새 환경·job 이탈·폴더)를 직접 만들어 한 줄도 돌기 전에 멈춘다. **부류 스윕:** 셀프테스트에서 승격 여부에 따라 갈리는 앱
  경로는 이 하나(`isElevated` 를 쓰는 곳은 링크뿐). **규칙:** 러너에서 도는 체크가 토큰·무결성·job 에 따라 갈리는 경로를 기대할 때는 그 값을 먼저 읽어 메모에 남기고 기대를 고른다.
<!-- agent link cold start (feat/windows-pet-link) end -->

<!-- gate robustness (ci/windows-gate-robustness) begin -->
## 윈도 유휴 게이트·셀프테스트의 경계 실패 네 건과 귀속 공백 (2523d9dc, 2026-11-18)

- **판정(14 회 full run 비교: windows-port 푸시 9 회 + kit/pc-10…14; 머지 #285·#287·#288·#289 전후에 앱이 한 일은 같다):**
  ① `idle.mainThreadCsPerMin 823.5 <= 800`(44295198366 shard 3, `popover-companion-animated-120s`) — **잡음.** 14 회 모두 루프 2394–2398·메시지 2393–2397·
  `animationClock` 1196–1198 로 같은 일을 했고, 주 스레드 전환만 662–824/분으로 흔들렸다(같은 SHA 의 kit14 692.5, #285 이전 kit11 799.0). 예산 800 은 621–726 을 보고 잡은 값이었다.
  ② `modalPump.idle` after=12(kit14 번들 재실행) — **잡음, 오늘 머지보다 오래됐다.** 안전 타이머 한 번은 약 45 회 중 거의 모두 1 회 전환이다(2523d9dc 포함). 같은 `[~5s+12]` 가
  #285 이전 트리(35a3a2b6, run 44225879845 설치 셀프테스트)에도 있었다. #285 의 새 로그·10 s 시계 점검 타이머는 상태가 바뀔 때만, `writeAndFlush` 는 종료·에이전트 링크에서만,
  #289 는 디스플레이 깨움·틱마다 `GetWindowLongW` 몇 번이라 안전 깨움 경로에 일을 더하지 않는다. 한 루프 반복에 12 회는 다른 프로세스가 모든 최상위 창에 보내는 메시지(브로드캐스트)의
  모양에 맞지만 그 창 안에 무엇이 왔는지 기록이 없었다.
  ③ `plaza.walk`(kit14 번들 첫 시도) — **입력·타이밍 플레이크.** "written=0" 은 통과한 모든 실행에도 있다. 같은 출발점(23,6)·같은 탭인데 세로 "down" 탭이 움직이지 않아 "up" 을 고르고,
  Shift+up 0.5 s 도 움직이지 않았다(y=6 그대로). 잠시 뒤 (28,6) 에서 up 은 3 칸 움직였다. Shift+up 자체는 오늘 13 회 통과했다. 두 키 동작이 1–2 s 안에 연달아 효과가 없었는데
  `loop.mainThreadStalls` 는 기동 때만 재서 키가 사라졌는지 펌프가 늦었는지 가를 수 없었다.
  ④ `plaza-closed-120s` 주 27.5/분(kit12 ff860ca6 첫 시도) — **모름(한 번).** 다른 13 회와 재실행은 2–3/분. 주 스레드 55 회, 디스패치 overcommit 스레드 232 회(통과 run 123).
  창의 귀속이 비어 있어 무엇이 깨웠는지 알 수 없다(아래).
- **귀속 공백(실제 결함): 32 창 중 17 창이 14 회 모두 깨움 귀속이 없었다.** IME 창의 클래스 이름 "MSCTFIME UI" 에 공백이 있어 `wake trace` 줄의 `messages=(\S*)` 가 맞지 않았고,
  `Get-WakeDelta` 는 null 을 돌려줬다 — 광장 창 넷, popover open/closed/kit/sprite, 페이지 창 아홉. 그래서 페이지 창의 "시계 없음" 규칙(#270 이후)은 볼 것 없이 통과해 왔다(cs·사이클
  예산은 적용됐다). **왜 못 걸렀나:** 귀속이 없으면 규칙이 조용히 건너뛰었고(`if ($w)`), 파서 테스트가 없었으며, 귀속을 가진 창(애니메이션·펫)만 봐서 빈 칸이 보이지 않았다.
- **고침(게이트·셀프테스트, 앱 동작은 그대로):** (4) `idle-rules.ps1` 이 줄을 키 이름으로 나눈다(공백 있는 클래스 이름 허용). 추적을 켠 창의 귀속이 없으면 그 창은 **실패**한다.
  (1) 애니메이션 두 창(`popover-companion-animated`·`popover-sprite-open`)은 한 일로 판정한다(`Test-AnimatedWork`): 시계 발화가 GIF 자신의 속도(프로브가 `gif rate=N/s` 로 적는다)의
  80–100 %(+10 s, +5), 메시지는 발화당 2 개 + 10 까지, 주 스레드 전환은 폭주 잡기(1000/분)로만. (2) `modalPump.idle` 은 창 안에 주 스레드로 온 것을 기록하고(`WinMessageArrivals`:
  다른 스레드·프로세스가 보낸 것 WH_CALLWNDPROC, 펌프가 꺼낸 게시 메시지 WH_GETMESSAGE) 예산을 넘으면 `IdleBurstAttribution` 이 **한 번의** 묶음만, 그것이 밖에서 온 브로드캐스트일
  때만 봐준다(같은 메시지가 우리 최상위 창 둘 이상에, 또는 알려진 시스템 브로드캐스트). 나머지는 여전히 예산 안이어야 하고, 귀속 없는 묶음·게시 메시지·한 창에만 보낸 것·두 번째 묶음은
  실패하며 판정에 이름이 남는다. (3) `plaza.walk` 의 `openDirection` 은 대체 방향도 시험하고, 둘 다 안 움직이면 한 번 더, 두 번째는 실패. 움직이지 않은 탭 쌍과 Shift 누름도 한 번 다시.
  펌프 지연(게시 메시지 왕복)을 걷기 전후와 다시 할 때마다 적는다. `plaza.walkRetry` 가 매 실행에서 증명한다(탭 둘을 일부러 보내지 않으면 다시에서 찾고, 넷이면 못 찾는다).
- **이빨 확인:** `idle-rules.tests.ps1`(CI `idle-rules.yml`, 50 검사): kit14 의 실제 줄 — 옛 패턴은 못 읽고 새 것은 읽는다; 14 회 28 창 모두 통과; 프레임마다 타이머 하나 더·
  컨트롤 하나 더 다시 그리기·두 배 속도 시계·멈춘 시계·1200/분 주 스레드·귀속 없음·속도 없음은 모두 실패. `IdleBurstAttributionTests`(7, 공용): 브로드캐스트·게시·나머지 규칙을 깨면 셋이 실패.
  **후속(같은 브랜치):** 움직이는 펫 두 창도 한 일로 판정한다(`Test-TimerWork`). `pet-working` 의 사이클이 같은 일(주 145/분)로 9 회 1.50–3.09 M/s 를 오갔고 예산 2.6 M 은 한 번의
  측정에서 잡은 값이었다(44315731795 첫 시도 실패, 재실행 통과). 귀속된 발화(GIF 시계 180–400, 일하는 에이전트의 흔들기 `petBob` — Foundation 타이머라 메시지가 아니어서 스스로 센다 —
  192–265)와 발화당 주 스레드 1.5 회 + 60 이하, 메시지 발화당 2 + 10 이하. 주 스레드·사이클은 폭주 잡기(400/분, 5 M/s)로만. 테스트: 측정한 모양은 통과, 두 번째 타이머·두 배 속도·
  멈춘 시계·다시 그리기 폭주·귀속 없음은 실패.
  **규칙:** 게이트 규칙이 읽을 값이 없으면 통과가 아니라 실패다. 로그 줄을 정규식으로 읽을 때는 값 안의 공백·구분자를 실제 줄로 시험한다. 측정 예산은 런너가 흔드는 양(전환 수)보다
  앱이 한 일(발화·메시지)에 건다.
<!-- gate robustness (ci/windows-gate-robustness) end -->

<!-- msvc toolset pin (ci/windows-msvc-toolset-pin) begin -->
## 러너 이미지가 바꾼 고정 안 된 빌드 입력: MSVC 툴셋 (2026-11-18, 이미지 20261116.315.1)
- **증상:** 새 `windows-latest` 이미지에 걸린 모든 빌드(windows.yml, windows-app, 릴리스 게이트)가 C++ 타깃(CPlazaD2D 등)에서
  `_EMIT_STL_ERROR(STL1000, "Unexpected compiler version, expected Clang 22 or newer.")` 로 컴파일 실패. 같은 코드가 이전 이미지(20261103.298.1)에서는 통과.
- **직접 원인:** 이미지가 VS 툴셋을 14.29/14.44/14.51 에서 14.29/14.44/14.52 로 바꿨다. clang 은 `VCToolsInstallDir` 가 없으면 가장 새 툴셋(14.52, STL 이 clang 22 요구)을
  고르는데 Swift 6.3.2 의 clang 은 20 이다.
- **왜 못 걸렀나:** 툴체인은 고정했지만(`swift-6.3.2-release`) 그 컴파일러가 맞물리는 STL 은 이미지가 정하는데 빌드 신원(시드 메타·릴리스 매니페스트)에 툴셋이 없었고,
  이미지 버전은 기록돼도 "이 툴셋이면 된다"를 확인하는 검사가 없었다. 이미지 롤아웃은 점진적이라 같은 날 이미지가 섞여 한쪽만 실패했다.
- **고침:** `scripts/windows/select-msvc-toolset.ps1` 이 설치된 툴셋의 `yvals_core.h` 가 요구하는 clang 버전을 읽어, 우리 clang 이 받아들이는 가장 새 14.4x+ 툴셋을
  `VCToolsInstallDir` 로 고정(없으면 실패). `windows-swift` 액션에서 실행하므로 windows.yml·windows-app·cache lab 이 모두 받는다. 새 이미지에서 14.44.35207, 이전 이미지에서
  14.51.36231 을 골랐고 둘 다 windows.yml 전체(4 조각 + render)가 통과. 시드는 툴셋이 다르면 쓰지 않고(`seed-meta.json` msvc), `windows-release.json` 에 `msvcToolset` 을 남긴다.
- **다른 고정 안 된 입력 점검(고정됨 / 안 됨):**
  고정됨 — Swift 툴체인(6.3.2, 작업 이름·버전 고정), MSVC 툴셋(이제 선택·기록), 시드의 Swift·이미지·툴셋·Package.swift 메타, 릴리스의 이미지 버전 기록.
  고정 안 됨 — runs-on `windows-latest`(이미지 롤링), Windows SDK(clang 이 가장 새 `10.0.x`; 두 이미지 모두 10.0.26100.0 이라 아직 같음), Inno Setup(이미지 것, 없으면 choco 최신),
  PowerShell 7(이미지), WARP/GPU 렌더러(OS 와 함께 바뀜: 유휴 예산과 광장 렌더 비교가 영향받음), vcpkg OpenSSL(`windows/vcpkg.json` 에 baseline 없음 → 항상 최신 3.x),
  swift-crypto(`from: "3.0.0"` 부동), `compnerd/gha-setup-swift@main`(브랜치 참조), 액션 `@v4/@v5` 태그.
  **후속 제안(사용자 결정):** 액션을 SHA 로, vcpkg baseline 을 고정, SDK 버전도 선택·기록.
- **규칙:** 컴파일러를 고정하면 그것과 맞물리는 헤더·툴셋도 고르고 기록한다. 러너 이미지가 정하는 입력은 빌드 신원에 남기고, 다르면 캐시를 쓰지 않는다.
<!-- msvc toolset pin end -->

<!-- pet frames on screen (fix/windows-pet-and-detail-animation) begin -->
- **(사용자 PC, kit 10–15) 플로팅 펫이 움직이지 않았다 — 로그는 "moving", 시계는 10 초에 92 번 돌았는데 화면의 그림은 그대로였다.** 사용자가 본 것: 펫 크기를 바꾸면 곧바로 커진다,
  "뒷모습"을 켜도 변화 없음, 쓰다듬어도 하트가 안 보이는데 포인터를 움직일 때마다 GIF 의 다른 프레임이 보인다. 직접원인: `WinPetWindow.render()` 가 같은 자리의 새 프레임을
  `UpdateLayeredWindow(hwnd, nil, nil, nil, …)`(자리·크기 NULL = "바뀌지 않음")로 올렸다. 그 호출은 성공하고 창의 비트도 바뀌지만, 그 PC(Windows 11 25H2, Intel UHD 620)에서는
  다른 일(포인터 위 툴팁·말풍선 창, 새 크기)이 그 자리를 다시 합성할 때까지 화면에 나오지 않았다. 크기 변경은 자리·크기를 넘기는 호출이라 보였다. **왜 못 걸렀나:** 펫 체크는
  전부 모델(프레임 번호·틱)과 `renders`(호출의 성공)를 셌고 화면의 픽셀을 본 적이 없다. kit 10 의 같은 보고는 내려받기·잠금 판정 쪽에서 원인을 찾았고("증명되지 않음"),
  kit 11 로그의 "moving" 을 화면이 움직인다는 증거로 읽었다. **고침:** 모든 갱신에 자리와 크기를 넘긴다(다른 레이어드 창 — 호버 카드·콜아웃 — 은 이미 그랬다). **부류 스윕:**
  `UpdateLayeredWindow` 호출 전수 — 펫 하나만 NULL 을 넘겼다. **회귀 테스트:** `pet.pixelsMove` — 실제 GIF·0.1 s 하한의 펫 상자를 화면에서 0.25 s 간격으로 열두 번 캡처해 프레임·그린
  그림·화면이 각각 바뀌는지 본다. 앱은 시계 점검 뒤 같은 다섯 번의 눈(프레임·그린 그림·화면·펫 창 수)을 로그에 남긴다. **규칙:** 움직임 체크는 모델이 아니라 화면 픽셀로 판정한다
  — 호출 성공·틱 수는 화면에 닿았다는 증거가 아니다. kit 10 의 앞선 결론("첫 GIF 요청 실패")은 이 원인으로 대체된다.
<!-- pet frames on screen (fix/windows-pet-and-detail-animation) end -->

## 어두운 모드에서 팝업 메뉴가 밝았다 (2026-11-19, 다크 메뉴)
- **증상:** 팝업은 어두운데 트레이·펫·드롭다운·입력 칸 우클릭 메뉴는 Windows 가 밝게 그려 어두운 화면에서 눈에 띄게 튀었다.
- **직접 원인:** Win32 팝업 메뉴는 프로세스가 앱 모드를 켜기 전에는 항상 밝다. 문서화된 방법은 항목 오너 드로우뿐인데 그러면 항목의 접근성 이름이 사라지고 메뉴 테두리는 밝게 남는다.
- **왜 못 걸렀나:** 어두운 모드 검사(Task 16)는 우리가 그리는 면과 공용 컨트롤의 시각 스타일만 봤고, 열린 메뉴의 픽셀을 본 검사가 없었다.
- **고침:** `WinMenuTheme` — `uxtheme` 서수 135/104/136 을 서수로 찾아(이름 가져오기 아님) 빌드별 형태(17763 미만 안 함, 17763-18361 불리언, 18362+ 열거형)로 호출하고, 실패·누락은 로그 한 줄 + 밝은 메뉴로 물러난다. 고대비는 기본 모드, 킬 스위치 `PTB_LIGHT_MENUS=1`.
- **부류 스윕:** 모든 메뉴는 `WinPopupMenu.run` 한 곳을 지난다(트레이·펫·드롭다운·대표 포켓몬). 입력 칸의 기본 우클릭 메뉴는 `WinControl` 서브클래스의 `WM_CONTEXTMENU` 에서 같은 `ensure()` 를 부른다.
- **영구 캡처:** `popover.darkMenu`(트레이·팝업·입력 칸 메뉴의 실제 픽셀, 강제 어둡게/밝게), `popover.darkMenu.fault`(킬 스위치면 밝게 남음), `popover.darkMenu.highContrast`(실제 High Contrast White 에서 어두워지지 않음).

## 컬렉션 쪽 넘김 화살표가 보이지 않았다 (kit 16, 2026-11-19, fix/windows-dex-pager-glyphs)
- **증상:** 사용자 PC 다크 모드에서 컬렉션 4×4 목록 아래 ‹ › 화살표가 배경에 묻혀 보이지 않았다("1 / 8" 글자는 보임). 라이트에서도 같았다.
- **직접 원인:** 그림(`DexBodyPart`)에는 화살표가 있었다 — 같은 부품을 오프스크린으로 그리면 13.8:1, 그림 비트맵의 화살표 칸에 잉크 픽셀 74·46 개. 그러나 그 위를 덮은 prev/next **항목 창**(오너 드로우 버튼)이 빈 배경만 칠했다.
  항목 창의 `paintItem` 은 `GdiAlphaBlend` 로 그림에서 자기 칸을 복사하는데, 쪽 넘김 버튼은 28 pt(Mac 의 `DexPageButton.hitSize`)이고 하단 바는 18 pt 라 항목 창이 그림 아래로 약 5 pt 삐져나온다.
  `GdiAlphaBlend` 는 **원본 사각형이 비트맵 밖으로 나가면 아무것도 그리지 않고 실패**한다 → `FillRect` 로 칠한 배경만 남았다. (글꼴 글리프 → 선으로 바꾼 것은 이 원인이 아니었다. 글리프 래스터도 따로 믿을 수 없어 선으로 바꾼 것은 유지.)
- **왜 못 걸렀나:** 글리프 대비 검사(`popover.glyphContrast`)는 부품을 **오프스크린**에서 그려 재거나 컨트롤의 색 쌍만 계산했고, 실제 창의 픽셀을 본 적이 없었다. 컬렉션 캡처는 사람이 보는 PNG 였을 뿐 화살표 칸을 재지 않았다.
  Mac 쪽 테스트는 같은 그림 경로라 같은 이유로 통과했다. 항목 창이 그림 위에 덮이는 경로(`paintItem`)는 어떤 테스트도 밟지 않았다.
- **고침:** `WinDrawnView.blit` 이 원본 사각형을 비트맵 안으로 잘라 복사한다(`blitOverlays` 는 이미 그랬다). 그림보다 큰 항목 창은 모두 같은 이유로 비었을 것이다.
- **부류 스윕:** `GdiAlphaBlend`·`BitBlt` 의 원본 사각형을 외부 값(항목 창 크기·위치)에서 받는 곳 — `WinDrawnView` 의 `blit`·`blitOverlays` 둘뿐이다. 그림보다 큰 항목: 쪽 넘김 버튼 둘(하단 바 18 pt 에 28 pt 버튼)뿐이다.
- **영구 캡처:** `collection.paging` 이 **실제 창의 픽셀**로 활성 화살표(1쪽의 다음, 8쪽의 이전)를 잰다 — 3:1 미만이면 실패(고치기 전 1.00:1, 고친 뒤 11.7:1). 항목 창이 덮는 칸·항목만 그린 값·항목을 숨긴 값을 한 줄에 남긴다.
  `popover.glyphContrast` 에 쪽 넘김(1·4·8쪽)과 결함쌍 `popover.glyphContrast.pagerFault`, Mac 쪽 `DexPagerInkTests`(1.5:1/3:1 하한, 화살표를 지우면 실패 확인), 스캔 테스트(리터럴 흑백 잉크·글리프 화살표 금지).
- **규칙:** 화면에 보여야 하는 것은 부품 모델이나 오프스크린 그림이 아니라 **창에서 캡처한 픽셀**로 잰다 — 그림이 맞아도 그 위의 창이 덮을 수 있다.

## 릴리스 스모크의 설치본 selftest 가 스프라이트 없이 돌았다 (2026-11-20, fix/windows-release-smoke)
- **증상:** v2.5.635 의 첫 `windows-release-smoke` 실행(44702891670)이 실패했다. 설치·버전·digest 까지 통과했고 설치본 selftest 에서 펫 검사 8개(`pet.hide`·`pet.noActivate`·`pet.drag`·`pet.clamp`·`pet.dpi`·`pet.clickActions`·`pet.menu`·`pet.zOrder`)가 실패, `pet.lateGIF`·`pet.pixelsMove` 는 "skipped: no PTB_SELFTEST_SPRITES"였다. 같은 설치본이 릴리스 자체의 `windows-app.yml` 실행(44697138418)에서는 통과했다. 스텝은 `timeout-minutes: 15`("약 6분")라 selftest 도중 잘렸다.
- **직접 원인:** 스모크는 selftest 환경을 `release-smoke.ps1` 안에서 따로 만들었고(`CLAUDE_CONFIG_DIR`·`PTB_STATE_DIR`·`PTB_SELFTEST_EXPECT_TODAY_TOKENS`), `windows-slice` 액션이 `windows-app.yml` 에 주는 `PTB_SELFTEST_SPRITES`(PokeAPI 픽스처 스프라이트 폴더)를 빠뜨렸다. 펫 검사는 그림이 있어야 펫이 뜬다. 스모크 타임아웃은 selftest 가 6분이던 때의 값이었다(지금 약 15분, 재시도까지 45분).
- **왜 못 걸렀나:** 스모크의 selftest 절반은 실제 릴리스에 대해 한 번도 돌지 않았다(스모크는 릴리스 뒤에만 돌고, 아티팩트 모드는 selftest 환경이 같은 빈 곳을 가졌다). `windows-app.yml` 쪽은 검사를 늘릴 때마다 액션에 환경을 더했지만, 같은 환경을 다시 만드는 두 번째 워크플로가 있다는 사실을 잇는 장치가 없었다.
- **부류 스윕:** `run-selftest.ps1` 을 부르는 곳은 `windows-app.yml`(번들·설치본, 둘 다 `windows-slice` 뒤)과 `release-smoke.ps1` 뿐이다. `PTB_FIXTURE`·`PTB_SELFTEST_SPRITES` 를 만드는 곳은 `windows-slice` 액션 하나다. 스모크가 유일한 재생성처였다. (`idle-gate.ps1` 은 `PTB_FIXTURE` 를 호출자 환경에서 받는다.)
- **고침:** 스모크가 `fetch-fixture-sprites.ps1` 로 스프라이트를 받아 `PTB_SELFTEST_SPRITES` 를 준다. 스텝 45분·잡 70분(`windows-app.yml` 설치 잡과 같다).
- **영구 캡처:** `scripts/tests/test_smoke_fixture_parity.py` — `windows-slice` 액션이 `GITHUB_ENV` 로 내보내는 `PTB_*` 변수를(버전·빌드 해시·`PTB_FIXTURE` 제외) `release-smoke.ps1` 이 모두 설정하는지, 같은 스프라이트 스크립트를 쓰는지 본다. `$env:PTB_SELFTEST_SPRITES` 줄을 지우면 실패하는 것을 확인했다.
- **규칙:** selftest 환경을 다시 만드는 두 번째 경로는 첫 경로의 변수 목록을 스캔 테스트로 따라간다. 타임아웃 주석의 "약 N분"은 같은 단계를 도는 다른 워크플로의 값과 함께 갱신한다.

## 셀프테스트·CI·개발 인스턴스가 운영 시트에 썼다 (usage-reporter 최종 리뷰, 2026-11-20)
- **증상:** 사용량 리포터가 팀이 준비된 앱이면 어디서든 회사 구글 시트로 POST 한다. CI 전용 윈도 셀프테스트 `settings.teamTransport` 는 앱의 `teamSettings` 를 몇 초간 준비 상태로 만들고, 그 사이 저장소 갱신이 일어나면 픽스처 멤버가 **운영 시트**에 기록된다. `scripts/plaza-dev.sh` 의 디버그 빌드(`PTB_STATE_DIR` + 준비된 팀)도 개발자를 이중 집계한다.
- **직접 원인:** 리포터를 시작하는 조건이 `TeamSettings.isReady` 하나뿐이었다. "이 인스턴스가 진짜 설치인가"를 묻는 조건이 없었다.
- **왜 못 걸렀나:** 리포터 테스트는 가짜 전송을 주입하므로 실제 전송이 나가는 경로를 한 번도 밟지 않았다. 셀프테스트는 팀 설정을 건드리는 검사와 리포터가 같은 앱 안에 산다는 사실을 아무도 겹쳐 보지 않았다 — 태스크별 리뷰는 각자 파일 안에서만 봤고, 최종 전체 브랜치 리뷰에서 처음 드러났다.
- **부류 스윕:** 앱의 바깥 쓰기는 이것 하나다. `UpdateChecker`·PokeAPI·한도 조회·팀 연결은 읽기이거나 팀원 사이 로컬 통신이다. 시트 리다이렉트 확인(`WindowsSelftestUsageReport`)은 지원하지 않는 버전으로 보내 시트가 거절하고 아무것도 쓰지 않는다.
- **고침:** `UsageReporter.shouldRun(stateDirectory:defaultDirectory:isSelftest:)` — 상태 폴더가 기본이고 셀프테스트 실행이 아닐 때만 리포터를 만든다(맥·윈도 공통). 아니면 리포터가 nil 이라 설정 줄은 "아직 안 보냄" 으로 읽힌다.
- **영구 캡처:** `UsageReporterTests.testOnlyARealInstallOutsideASelftestReports`(네 분기), `windows-app.yml` 의 "No usage report from selftests" 단계 — 수집한 앱 로그에 `usage report sent|rejected|failed` 줄이 있으면 실패한다.
- **규칙:** 셀프테스트·CI·개발 인스턴스는 운영 서비스에 쓰지 않는다. 바깥으로 쓰는 코드를 더할 때는 그것을 켜는 조건에 "진짜 설치인가"를 넣고, 그 조건을 CI 가 로그로 한 번 더 확인하게 한다.

## 저장소 전체 스캔 테스트가 병합 뒤 CI 에서야 걸렸다 (usage-reporter #311, 2026-11-20)
- **증상:** #311 병합 뒤 맥 CI 와 윈도 테스트 shard 1 이 실패했다. ① `TeamReleaseScriptTests.testTeamGuideHoldsNoPrivateDetails` — 새 TEAM.md 문장 "이메일의 도메인(@ 뒷부분)" 의 `@` (TEAM.md 에는 `@` 가 하나도 없어야 한다). ② `WindowsSeamScanTests.testNoRequestOutsideTheSeamInCodeThatRunsOnWindows` — 새 셀프테스트 `WindowsSelftestUsageReport` 가 `WinHTTPFetch.data(for:)` 를 직접 불렀다.
- **직접 원인:** ① 문서 규칙(개인정보처럼 보이는 글자 금지)을 모른 채 설명용으로 `@` 를 썼다. ② 클라이언트 인증서 점검을 본떴는데, 그 파일은 대조군 때문에 직접 호출 허용 목록에 있고 새 파일은 아니었다.
- **왜 못 걸렀나:** 계획의 검증 단계가 태스크마다 필터 몇 개(`UsageReport*`, `SharedSourcesScanTests`, `SettingsModelTests` …)만 돌렸다. 새 파일·문서가 걸릴 수 있는 저장소 전체 스캔(`*ScanTests`, `TeamReleaseScriptTests`)은 아무 태스크도 돌리지 않았다. 리뷰어도 스캔 규칙을 모른 채 모델 파일과의 일치만 봤다. 린 흐름대로 CI 를 기다리지 않고 병합했으므로 CI 가 마지막 그물이었다(설계대로 작동).
- **부류 스윕:** 같은 PR 의 다른 새 네트워크 호출은 `HTTPUsageReportTransport`(이음매 `PlatformCompat.oneShotData` 를 씀) 하나다. TEAM.md·README 의 새 문장에 `@`·`.local` 은 더 없다.
- **고침:** TEAM.md 는 "(예: likelion.net)". 셀프테스트는 리포터와 같은 이음매(`PlatformCompat.oneShotData`, 점검용 세션의 10 s/15 s 설정)로 보낸다 — 앱의 실제 경로를 확인하게 되어 더 맞다. `WindowsSeamScanTests.routedSites` 에 두 호출 지점을 올렸다.
- **규칙:** 공용 코드에 네트워크 호출을 더하거나 TEAM.md·README·`scripts/team-release.sh` 를 고치는 브랜치는 PR 전에 `swift test --filter 'ScanTests|TeamReleaseScriptTests'` 를 한 번 돌린다. 계획을 쓸 때 이 줄을 해당 태스크의 검증 단계에 넣는다.

## 사용량 시트의 팀 하나가 통째로 미지정이 됐다: 다수결 뒤에 기본 이름을 걸렀다 (2026-11-23, fix/usage-sheet-dept-vote)
- **증상:** 한 팀의 팀원들이 2.5.638 로 보고를 시작하자 운영 시트의 부서 표가 비고, 그 팀 전원의 토큰이 "미지정" 한 줄로 갔다. 전날 팀 이름을 바꾼 한 명만 보고할 때는 정상이었다.
- **직접 원인:** `suggestedTeamNames` 가 팀원이 보낸 팀 이름의 다수결로 참고팀이름을 고르고, `departmentOf` 가 그 결과가 기본 이름(`팀 N`)이면 버렸다. 팀 이름은 팀원마다 자기 앱에서 정하고 대부분 "팀 1" 로 두므로 다수결은 늘 "팀 1" 이고, 거르기가 다수결 *뒤*에 있어 바꾼 이름이 있어도 미지정이 됐다. 또 대시보드는 표결 전에 읽은 데이터로 그려서, 표결이 바뀌어도 한 번 늦게(다음 정시 갱신에) 반영됐다.
- **왜 못 걸렀나:** #326 테스트는 `departmentOf` 에 참고팀이름을 직접 넣었고, 표결 테스트는 바꾼 이름이 다수인 팀만 썼다. "다수가 기본 이름, 소수만 바꿈" 이라는 실제 팀 모양이 표결과 거르기를 함께 거치는 경로가 없었다. 팀 이름이 팀원별 값이라는 사실을 설계가 놓쳤다.
- **부류 스윕:** 시트에서 팀원 입력을 다수결로 모으는 곳은 `suggestedTeamNames` 하나다. 닉네임·합칠대상은 표결하지 않는다.
- **고침:** 표결에서 바꾼 이름이 기본 이름보다 먼저다(기본 이름만 있는 팀은 그중 다수). `writeSuggestedTeamNames` 는 새 참고팀이름을 그리기용 데이터에도 넣는다.
- **영구 캡처:** `admin.test.js` "refreshAll skips the default team names when a member renamed the team, however many kept the default" — 기본 이름 5표·바꾼 이름 1표씩, 기본 이름만 있는 팀, 같은 갱신에서 그려지는지. 두 고침을 하나씩 되돌리면 각각 실패한다.
- **규칙:** 여러 사람이 보낸 값을 모아 하나를 고른 뒤 거르는 코드는, 거를 값을 표결 전에 빼거나 뒤로 미룬다. 테스트는 "거를 값이 다수" 인 입력으로 표결과 거르기를 함께 지나게 한다.

## Fable 5.2 · Haiku 5.5 가 가격표에 없어 비용이 "계산 불가"였다 (2026-11-20, fix/price-claude-5-models)
- **증상:** 오늘·주·월 비용 줄이 "계산 불가"로 나왔다(맥·윈도우 공통). 앱 로그에 `Unpriced model: claude-fable-5-2`, `claude-haiku-5-5` 가 남아 있었다.
- **직접 원인:** `ModelPricing.table` 은 정확한 모델 이름만 받는다(#289 에서 계열 폴백 제거). 새 모델 두 개의 줄이 없었다.
- **왜 못 걸렀나:** `testModelsReadFromProviderLogsAreAllPriced` 는 손으로 적어 둔 이름만 본다. 새 모델이 나왔다는 사실은 테스트가 알 수 없고, 알려 주는 장치는 실행 중 로그 한 줄(`noteUnpriced`)뿐인데 그 로그를 릴리스 전에 보는 절차가 없었다.
- **부류 스윕:** 이 맥의 앱 로그에서 `Unpriced model` 을 전부 모았다 — 위 두 개뿐이다.
- **고침:** 두 모델의 줄 추가(공식 가격표 2026-11-20 확인: Fable 5.2 $8/$40/$10/$0.20, Haiku 5.5 $0.10/$0.50/$0.125/$0.01). Haiku 5.5 는 프롬프트가 100,000 토큰을 넘으면 모든 항목이 5배라 `estimatedCost` 에 그 단계를 넣었다.
- **영구 캡처:** `testFable52AndHaiku55Rates`(100,000 경계 양쪽), `testModelsReadFromProviderLogsAreAllPriced` 목록에 두 이름 추가. 줄을 넣기 전 4건 실패를 확인했다.
- **규칙:** 릴리스 전에 릴리스 맥의 앱 로그에서 `Unpriced model` 을 grep 한다. 나오면 그 릴리스에 가격 줄을 넣는다.

## 윈도 설정에 행 하나를 더했더니 페이지 열기 비용 예산을 넘었다 (v2.5.636 릴리스 실행, 2026-11-20)
- **증상:** v2.5.636 릴리스의 windows-app 실행(44748321973)이 `settings.openCost` 에서 멈췄다: Home → Settings 전환이 "5 frames with a paint (budget 4)". 공개된 것은 없다.
- **직접 원인:** #311 이 팀 카드에 사용량 보고 줄을 **자기 행**(Static 하나 + 구분선)으로 더했다. 설정 페이지의 창이 164 → 165 개가 되고, 전환 때 그려지는 프레임이 3–4 에서 3–5 로 퍼졌다. #311 이전 실행 9개는 모두 3–4(예산 4 의 가장자리), 이후 4개는 3·3·5·5.
- **왜 못 걸렀나:** ① PR 실행 두 번은 우연히 3 프레임으로 통과했다. ② 브랜치의 첫 windows-app 실행(44707310118)은 `FAIL settings.openCost` 를 찍었지만 그 모드에서는 이 검사가 잡을 막지 않아 잡은 초록이었고, 잡 결론만 읽고 셀프테스트의 개별 결과는 읽지 않았다. ③ 리뷰는 "맥과 같은 문구·위치"만 보고 Win32 에서 행 하나가 창 하나와 구분선 하나라는 비용은 보지 않았다.
- **고침:** 보고 줄을 일정 캡션과 **같은 힌트**의 둘째 줄로 넣는다(`SettingsModel.teamCaptionLines`, `WinTeamSection.caption` 이 CR LF 로 잇는다). 창 수는 다시 164 개이고, 맥처럼 두 줄 사이에 구분선이 없다(전의 별도 행은 맥에 없는 구분선을 그렸다).
- **영구 캡처:** `SettingsModelTests.testTheReportLineFollowsTheScheduleCaptionOnlyWhileTheTeamIsReady`. 예산 자체는 `settings.openCost` 가 이미 지킨다 — 릴리스 모드가 막는다.
- **규칙:** 윈도 팝오버 페이지에 행을 더하기 전에, 기존 행의 힌트나 라벨에 넣을 수 있는지 먼저 본다. 행을 더했다면 PR 의 windows-app 실행에서 `settings.openCost`·`popover.swapCost` 줄의 `frames with a paint`·`windows made` 를 직접 읽는다(잡이 초록이어도).
- **후속(같은 날, 두 번째 릴리스 실행 44764713785):** 창이 164 개로 돌아온 뒤에도 설치된 앱의 셀프테스트가 5 프레임을 두 번 쟀다. 둘째 줄이 두 줄로 감겨 설정 페이지가 v2.5.635 보다 32 px 컸고(2356 → 2388), 전환이 3 프레임 위주에서 4 프레임 위주로 옮겨 느린 러너에서 5 가 됐다. 사용자 결정으로 문구를 한 줄로 줄였다: "회사 대시보드로 보내는 중 · 11월 20일 16:05" / "… · 아직 안 보냄"(맥·윈도 같은 문구). 예산(4)은 그대로 둔다.
- **재발(#350 팀 이름 동기화, 2026-11-23):** 팀 만들기에 이름 칸·오류 줄, 팀 이름 아래 안내 줄을 더해 창이 164 → 168 개가 됐고, PR 의 windows-app 실행이 `settings.openCost` "168 windows made (budget 164)" 로 막혔다. **왜 못 걸렀나:** 구현 지시와 브랜치 리뷰가 이 규칙(행을 더하면 창 예산)을 말하지 않았고, 맥에서는 윈도 코드를 빌드·실행할 수 없어 PR 실행 전에는 볼 수 없었다. 게이트는 제대로 막았다. **고침:** 이름 칸은 읽기 프로그램용 이름(라벨 또는 `accessibleName` 의 static)이, 오류와 안내는 각자 static 하나가 꼭 필요해 줄일 수 없어 예산을 168 로 올리고 이유를 코드에 적었다. 그 상태(팀에 들어 있음)에서 새로 보이는 것은 안내 한 줄뿐이고 PR 실행은 3·4 프레임(예산 5)이었다. 안내를 팀 이름 행의 힌트로 옮겨 보기도 했지만 창 수는 같고(힌트도 static 하나) 힌트가 라벨 칸에 들어가 두 줄로 꺾여서, 맥처럼 한 줄로 보이는 따로 된 행으로 되돌렸다(#350 다음 PR). 힌트로 옮기는 것은 기존 static 의 글을 늘릴 때만 창을 줄인다. **규칙 보강:** 윈도 팝오버에 행·힌트를 더하는 구현 지시에는 `settings.openCost` 창 예산을 적는다.

## 광장 패널의 "쉴 때 렌더 없음" 검사가 가끔 하나를 더 셌다 (#319 CI, v2.5.636 세 번째 릴리스 실행, 2026-11-21)
- **증상:** `PlazaBoardWindowTests.testOpeningAndClosingNeverRelayoutsTheHostAndTheIndicatorEndsItsTimers` 가 "idle and visible: no renders" 에서 36 ≠ 35 로 실패했다. #319 의 맥 CI 에서 한 번(재실행은 통과), 같은 날 릴리스 맥 게이트에서 한 번. 앞선 릴리스 게이트 두 번은 통과했다. 바뀐 코드는 광장과 무관한 문구뿐이었다.
- **직접 원인:** 스크롤 표시의 마지막 사라짐 박자(`PlazaScrollIndicator` 의 fade `onTick`)는 시계를 먼저 멈추고(`isTimerRunning == false`) 렌더는 `PlazaHUD.setNeedsRender` 가 **다음 메인 액터 Task** 로 미룬다. 시계는 메인 런루프의 `Timer` 라, 테스트의 `rig.wait`(20 ms 마다 조건 확인) 가 그 사이에 깨면 조건이 참이 된 채 렌더 전 수를 `idle` 로 읽고, 미뤄 둔 렌더는 이어지는 1 초 안에 들어와 하나가 더 세진다. 부하가 큰 맥(전체 스위트)·러너에서 그 틈이 넓어진다.
- **왜 못 걸렀나:** 테스트는 "타이머가 멈췄다 = 렌더도 끝났다" 를 가정했고, 보통은 Task 가 깨어난 wait 보다 먼저 돌아 통과했다. `rig.wait` 의 주석이 느린 러너를 다뤘지만(고정 sleep 대신 조건 대기) 조건 뒤에 남은 일은 다루지 않았다.
- **부류 스윕:** `rig.wait` 호출 3곳(보드 1, 채팅 기록 2 — 하나는 렌더를 끈 상태라 무관)과, 같은 "타이머 끝난 뒤 렌더 수 읽기" 를 고정 1.6 s sleep 으로 하던 카드 테스트 하나. 로스터 테스트는 시계가 처음부터 없는 상태를 재서 해당 없다. 윈도 셀프테스트(`WindowsSelftestPlazaPanels`)는 0.5 s 펌프 뒤 1–5 범위로 재서 해당 없다. 제품 코드는 바꾸지 않는다 — 마지막 박자의 렌더(투명도 0)는 맞는 동작이다.
- **고침:** `PlazaWindowRig.wait` 가 조건이 참이 된 뒤 `flush()`(20 번 yield)로 미뤄 둔 렌더를 끝내고 돌아온다. 카드 테스트의 1.6 s sleep 을 `rig.wait { !isTimerRunning }` 로 바꿨다.
- **영구 캡처:** `PlazaBoardWindowTests.testTheRigsWaitReturnsAfterAScheduledRenderLands` — `setNeedsRender` 직후 `wait { true }` 가 렌더 수 +1 을 보여야 한다. `flush()` 를 빼면 매번 실패한다(결정적).
- **규칙:** 광장 HUD 의 렌더 수를 읽기 전에는 `rig.flush()` 나 `rig.wait` 를 거친다. 시계·타이머 상태가 바뀐 직후라도 렌더는 아직 예약만 된 상태일 수 있다.

## 창 끝에 걸친 저장소 갱신이 유휴 예산에서 빠졌다 (v2.5.636 네 번째 릴리스 실행, windows-app 44868486165, 2026-11-21)
- **증상:** 번들 셀프테스트("Selftest with a stripped Path")의 `ui.kit.idle` 이 `main_thread_cs=39 (budget 11 … refresh:0)` 으로 실패해 릴리스가 5단계에서 멈췄다. 같은 셀프테스트의 앞선 실행 넷(44748321973·44758347740·44764713785·44864690889)은 37–40 회로 **같은 일**(주 스레드 약 40, `com.apple.root.user-initiated-qos` 일꾼 셋)을 했고, 그때마다 `refresh:1` 이라 예산이 71 이었다.
- **직접 원인:** 앱은 갱신을 **끝날 때만** 센다(`UsageStore.refresh` 끝의 `onRefresh` → `refreshCount += 1`). 이번에는 갱신이 10 s 창 안에서 시작해 창이 끝난 뒤 끝났다 — 일(파싱 스레드, 주 스레드 전환)은 창 안에, 셈은 창 밖에 떨어져 예산에 60 이 빠졌다.
- **왜 못 걸렀나:** 갱신(120 s 마다)이 창 안에서 끝나는 경우와 창 밖에 있는 경우만 겪었다. 걸친 경우는 위상이 맞아야 나와 처음이었다. `team.idle` 은 같은 구멍을 이미 막았지만(`refreshStarted` 관찰) 그 방법이 공용 셈으로 올라가지 않아 다른 유휴 검사 넷은 옛 셈(끝난 수의 차이)을 그대로 썼다.
- **부류 스윕:** 갱신을 예산에 넣는 유휴 검사 다섯 — `ui.kit.idle`(`WindowsSelftestPopover`), `modalPump.idle`(`WindowsSelftestModal`), `pet.idle` 의 창(`WindowsSelftestPopoverPet`, 갱신이 든 창은 한 번 더 잰다 — 걸친 갱신은 그 재측정도 못 불렀다), `idle.window`(`WindowsSelftest`), `team.idle`(이미 막음). `popover.idleAttribution` 은 예산 없이 적기만 해서 해당 없다.
- **고침(셀프테스트만, 앱 동작은 그대로):** `IdleBurstAttribution.refreshesInWindow(countBefore:countAfter:runningAtEnd:)` — 창 안에서 끝난 수 + 창 끝에 아직 도는 갱신 하나. `onRefresh` 는 `isRefreshing` 이 내려가기 전에 불리므로 "끝에 도는 중" 이면 아직 안 센 갱신이다. `KnownWakes` 가 `refreshing` 을 담고 `refreshesInWindow(since:)` 로 네 검사가 같은 셈을 쓴다. 기록 줄은 `refresh:0+running` 처럼 보인다.
- **영구 캡처:** `IdleBurstAttributionTests.testARefreshStillRunningAtTheWindowsEndIsBudgeted`(도는 중만·끝난 것만·둘 다·없음).
- **규칙:** 유휴 창에서 앱의 일을 셀 때는 "끝난 수의 차이" 만 쓰지 않는다 — 창 끝에 진행 중인 일도 센다. 같은 셈이 둘 이상의 검사에 있으면 공용 함수 하나로 모은다.

## 큰 나무가 윈도에서 처음 돌았더니 사진 골든·한낮·2.5배 가장자리가 틀렸다 (#327 윈도 CI 44913341032, 2026-11-21)
- **증상:** 윈도 CI 가 세 가지로 실패했다. ① `WindowsPlazaClipboardTests.testPhotoBytesLookLikeTheMacs` 가 나무가 든 사진마다 맥과 3만~21만 픽셀 달랐다(윈도가 나무의 윤곽색 `#222034` 를 그렸는데 맥 골든에는 풀밭). ② `PlazaTreeLayerTests.testThePhotoCarriesTheTree` 가 "눈 잎 색이 사진에 없다". ③ 교차 렌더 비교가 6건 실패: `base-noon-1.25x@10/40/90`, `big-tree-hit-3@6/12`(1 픽셀 줄이 27 픽셀마다), `chat-bubbles-1x@10`(말풍선이 113 pt 다른 자리).
- **직접 원인(셋 다 다르다):**
  1. 맥 사진 골든(`Tests/PlazaParityGoldens/photos`)이 나무 이전 것이었다. 맥 검사 `testPhotoGoldensStillHoldOnThisMac` 는 `TimeZone` 이 UTC 가 아니면 **건너뛴다**: 개발 맥(KST)과 맥 CI 는 건너뛰고, UTC 러너인 윈도 CI 에서만 처음 비교됐다. 윈도 사진은 맞았다(새 골든과 나무 영역이 같다: 눈 잎 색 11,484 픽셀이 맥과 같다).
  2. 테스트 시계(`PlazaFixtureTime`)는 KST 한낮 12:00 이고 장면은 `Calendar.current` 로 낮밤을 읽는다. UTC 러너에서는 그것이 03:00 이라 사진에 밤 색조가 곱해져 눈 잎이 제 색이 아니었다.
  3. 나무는 3배로 그려서(`scale` 3) 나무 픽셀 가장자리가 3 월드 픽셀 간격인데, 기기 배율이 2.5(줌 2 × 배율 1.25)면 가장자리가 두 개 걸러 하나씩 기기 픽셀 **한가운데**에 놓인다. 거기서 최근접 표집은 SpriteKit 과 Direct2D 가 서로 다른 쪽을 고른다(수학적으로 동점). 세로 때림(`yScale` 1.125)에서는 나무 픽셀 높이가 13.5 기기 픽셀이라 같은 일이 때림 장면마다 났다. 말풍선은 별개다: 장면의 Ash 를 (14,9) 로 옮기자 그 이름표가 화면 가장자리(`|plate.x| = halfW`)에 정확히 걸려 `chatBubbleOrigin` 의 "이름표가 화면 밖이면 그대로" 판정이 OS 마다 갈렸다(옛 위치에서는 가장자리가 아니었다).
- **왜 못 걸렀나:** ① 맥 골든 검사의 건너뛰기(UTC 아님) — 맥에서는 아무도 그 비교를 돌리지 않았다. ② 같은 시간대 가정: 맥(KST)에서는 한낮이 한낮이다. ③ `swiftc -parse` 와 맥 테스트는 윈도 코드(`#if os(Windows)`)와 윈도의 샘플링을 볼 수 없다; 맥 교차 기준은 "맥이 맥과 같다" 만 증명하고, 윈도와의 비교는 윈도 CI 만 한다. 옛 장면은 모두 정수 배율(2배)이거나 비교가 허용 오차로 흡수한 크기(1.25배는 0.5 %)였고, 나무는 처음으로 7.5 픽셀 덩어리를 만들었다.
- **고침:** ① 골든 다시 만들기(`TZ=UTC PTB_PLAZA_GOLDENS_WRITE=1`)와, 맥 골든 검사가 건너뛰는 대신 프로세스 시간대를 UTC 로 잠시 두고 돌게 했다(이제 어디서나 비교한다. 옛 골든을 되돌리면 실패하는 것을 확인했다). ② `treeScene` 이 `PlazaFixtureTime.pin()` 으로 시간대를 고정한다. ③ `PlazaTreeLayer.nudge(step:)`: 나무 전체를 기기 픽셀의 1/64 만큼 비껴 놓아 어떤 가장자리도 픽셀 한가운데에 놓이지 않게 했다. 정수 배율에서는 가장자리가 픽셀 경계에 있어 그림이 바이트까지 그대로다(맥 교차 기준에서 정수 배율 장면의 픽셀은 하나도 안 바뀌었다). 비용: 노드 값 하나(루트 위치)가 배율이 바뀔 때만 쓰인다. 말풍선은 장면의 Ash 를 (15,12) 로 옮겼다.
- **부류 스윕:** 윈도 CI 에서만 비교되는 것: 사진 골든(맥 쪽 검사를 이제 항상 돈다), 교차 렌더(맥 기준 187장). 비정수 배율로 그려지는 새 그림: 나무 띠·잎(루트 아래라 같은 비킴을 받는다), 별(0.6→1.9 배, 효과가 짧고 기존 태클 별과 같다), 김(`PlazaSteam.scale` 2 → 1.25 배율에서 5 픽셀 정수), 온천 몸통 붉은 복사본(원본 크기). 1.25·1.5배 장면은 `base-noon` 만이라 온천·김은 비정수 배율에서 윈도와 비교되지 않았다 — 닫았다(교차 렌더에 `hot-spring-1.25x` 장면, 맥 기준 189장. 윈도 `render` 잡 통과). 시간대 가정: `PlazaFixtureTime.date` 를 쓰는 장면 테스트는 이 나무 테스트뿐이다.
- **영구 캡처:** `PlazaTreeLayerTests.testNoTreePixelEdgeSitsOnADevicePixelCentre`(줌 1·2·3 × 배율 1·1.25·1.5·2, 쉴 때와 늘어난 때: 가장자리가 기기 픽셀 중심과 0.005 이상 떨어져야 한다. 비킴을 빼면 838건 실패), `PlazaPhotoGoldensMacTests.testPhotoGoldensStillHoldOnThisMac`(이제 건너뛰지 않는다).
- **규칙:** 3배 이상 확대해 그리는 새 그림은 비정수 기기 배율(2.5, 7.5)의 동점 표집을 피하게 비껴 놓는다. 시간대나 환경 때문에 건너뛰는 맥 검사는 만들지 않는다(환경을 고정해서 돌린다). 윈도 CI 첫 실행에서 "윈도에서만" 실패가 나오면 맥 골든·고정 시계·샘플링 동점부터 본다.


## 2026-11-22 — A plaza PR passed `Plaza|Team` locally and failed CI on tests that pin the plaza's structure under other names (#330)

- **Symptom:** the minigame PR (#330) ran 2,965 `Plaza|Team|…` tests green on the Mac and failed CI three ways: `SpriteKitMirrorParityTests` (the new actor against the frozen legacy actor: one more camera node, a changed sprite colour), and the Windows-only `WindowsPlazaPanelsTests` (the pinned panel list and counts).
- **Cause:** a new always-attached actor node and a default sprite colour changed what every actor is, also outside a game; two new HUD panels changed the pinned panel order.
- **Why the tests did not stop it locally:** the filter `Plaza|Team` does not match `SpriteKitMirrorParityTests` (the plaza's render-parity suites have names without "Plaza"), and Windows-only test files do not compile on the Mac at all.
- **Fix:** the bomb node joins the camera only while an actor holds a bomb and the soot colour is set only by a blast, so an actor outside a game is node-for-node what it was (no reference regenerated); the Windows panel expectations were updated.
- **Class rule:** a plaza change that adds a node, a panel or a default node property must (1) run `swift test --filter "Plaza|Team|SpriteKit|Mirror"` plus the guard suites, and (2) grep `Tests/PokeTokenBarTests/Windows*.swift` and `Platform/Windows` for the pinned lists it touches (`zOrder`, `drawList.count`, panel ID lists) before pushing. Prefer mounting optional nodes on demand over growing every actor.

## 큰 나무의 하루 횟수가 시계를 앞으로 돌리면 잠기고, 받은 `treeDrop` 을 그대로 그렸다 (v2.5.637 감사, 2026-11-22)
- **증상:** ① `PlazaTreeDay.hit(on:)` 은 `today > day` 일 때만 처음부터 셌다. 시계를 한 번 앞으로 돌리거나(시간대를 건넌 경우도 같다) 그 날 한 번 치면 저장된 날이 미래가 되고, 그 뒤로는 그 미래 날짜에 이어 셌다. 그 날 아직 못 받았으면 민트가 한 번은 나왔지만, 한 번 나온 뒤에는 진짜 날이 그 날짜에 닿을 때까지 민트가 다시 나오지 않았다. ② 팀원이 고친 앱으로 `treeDrop` 에 이로치 부적·이상한 사탕을 보내면 모든 화면에 그 아이템이 떨어지는 그림이 그려지고, 나무의 아이템 자리(하나뿐)가 한동안 차 있어 진짜 드랍이 그려지지 못했다.
- **직접 원인:** ① 날 키를 순서로 비교했다(되감긴 시계 부류의 방어를 "키는 사전순으로 시간 순서다" 라는 가정으로 만들었다). ② `showTreeShake` 가 디코드된 `ItemKind` 를 그대로 `playTreeHit` 에 넘겼다(디코드는 알려진 종류만 거르지, 그 종류가 이 상황에 맞는지는 보지 않는다).
- **왜 못 걸렀나:** ① 테스트가 되감기(`testAClockSetBackGivesNoSecondMint`)만 만들고 앞으로 돌린 시계는 만들지 않았다: 방어의 한쪽 방향만 검증해서 반대 방향의 잠김을 못 봤다. 음력처럼 사전순이 시간순이 아닌 키도 시험하지 않았다. ② 적대 피어 테스트(`testAbsurdTreeShakesBecomeHarmless`)는 디코드 단계(모르는 종류는 nil, 단계는 범위 안)만 봤고 "알려진 종류지만 이 자리에 올 수 없는 값" 이 화면에 닿는 길은 보지 않았다.
- **고침:** ① 키가 **다르면**(앞이든 뒤든) 처음부터 센다. 키의 앞뒤를 보지 않는다(시계를 바꿔 다시 받을 수 있는 것은 알고 받아들였다: 광장의 다른 하루 기록과 같다). ② 받은 드랍은 `PlazaTree.dropItem` 이고 단계가 맨 위일 때만 그린다. 아니면 흔들림만 그린다.
- **부류 스윕:** 나무 코드에는 날 키를 `<`/`>` 로 비교하는 곳이 더 없다(`dayKey` 는 바꾸지 않았다: 동등 비교만 쓰면 음력 키도 된다). 광장의 `PlazaActivity` 는 `rolled(to:)` 가 `==` 로 본다. 광장 밖의 사용량 장부(`UsageReportLedger`, `UsageRecap`, `ClaudeAccountUsage`, `LocalUsageReader`)는 날 키를 순서로 비교하지만 그곳은 "범위 안인가" 를 묻는 조회라 이 결함(방어를 위한 비교)이 아니다. 피어가 보낸 값이 화면의 단일 자리(아이템 슬롯)를 차지하는 다른 경로는 없다(`treeDrop` 뿐).
- **영구 캡처:** `PlazaTreeTests.testADifferentDayKeyInEitherDirectionStartsOver`(앞·뒤·음력 키, 모든 나무), `TeamRuntimeTests.testAHostileTreeDropShowsNoItem`(실제 받기 경로: 이로치 부적·이상한 사탕·낮은 단계의 민트는 아이템 없이 흔들림만, 진짜 드랍은 그려짐. 가드를 빼면 4건 실패).
- **규칙:** 시간 방어는 앞·뒤 두 방향을 모두 시험하고, 날 키는 같은지만 본다. 피어가 보낸 값이 화면의 한정된 자리를 차지하면, 디코드가 통과해도 "그 값이 이 순간에 올 수 있는가" 를 받는 쪽에서 다시 거른다.

## 대각선 몸통박치기가 거꾸로 밀고, 나무 너머로 쳐지고, 눈덩이가 나무를 지나고, 사진·캐시·셀프테스트 여덟 건 (v2.5.637 감사의 남은 Minor, 2026-11-22)
- **증상:** ① 큰 몸이 대각선으로 닿은 팀원을 칠 때 `PlazaTargeting.turn` 이 동점이면 `facing` 을 돌려줘서, 때리는 쪽은 허공으로 뛰어들고 맞는 쪽은 때리는 쪽 쪽으로(또는 지나쳐) 밀렸다. ② 큰 몸의 다른 칸이 나무를 마주 보면, 발 앞 칸에 팀원이 서 있어도 C 가 그 팀원을 지나 나무를 쳤다. ③ 나무가 없던 옛 지도의 팀원(또는 고친 앱)이 나무 너머로 던진 눈덩이가 내 쪽에서 나무를 그냥 지나 나를 밀었다(`hitTile` 이 지도를 안 봤다). ④ 한 앱이 멤버 ID 를 여러 개 대면 보낸 사람마다 1초 규칙을 피해 1초에 N 번 나를 밀었다. ⑤ 사진이 땅에서 흐려지는 잎을 불투명하게 찍었다. ⑥ 온천에서 나간 팀원의 붉은 기운이 빠지는 60초 동안 단계마다 모든 프레임을 구워 두었다가 0단계에서야 버렸다(프레임 × 6장). ⑦ 작은 지도가 계절마다 전체 크기(6MB) 나무 얹은 지도를 프로세스가 끝날 때까지 쥐었다. ⑧ 윈도 `plaza.renderCostTree` 는 `isTreeShown`(층이 있으면 늘 참)만 봐서 가만히 선 나무를 재고도 통과했고, `plaza.shotTree` 는 잎이 터지기(0.2초) 전 프레임을 찍었다.
- **직접 원인:** ① 명세 6.3 의 "같은 축 차이면 facing" 을 때리는 쪽의 돌아서기와 미는 방향 둘 다에 썼다(동점에서 facing 이 상대 반대쪽일 수 있다는 것을 안 봤다). ② 나무를 팀원보다 먼저 검사했고 `isFacing` 은 몸의 모든 칸을 본다. ③ 받는 쪽 확인이 보낸 쪽의 직선을 믿었다(`.drag`·`.pull`·`.tackle` 은 이미 내 지도로 확인한다). ④ `PlazaShove` 가 보낸 사람 ID 로만 키를 잡았다(ID 는 자기 신고다). ⑤ `drawProps` 가 입자의 알파를 안 썼다(얼음·날씨 반복문은 쓴다). ⑥ `setFlush` 가 0단계에서만 비웠다. ⑦ 계절별 정적 캐시. ⑧ 셀프테스트 판정이 "층이 있다" 였다.
- **왜 못 걸렀나:** ① 테스트가 명세의 동점 규칙을 그대로 못 박았고(`dir(6,6,.down) == .down`), "맞는 쪽이 때리는 쪽에서 멀어지는가" 는 아무도 안 물었다. ② 나무 테스트의 팀원은 옆이나 줄기 안에만 있었고 큰 몸의 발 앞 칸에 선 경우가 없었다. ③ 눈덩이 테스트는 보내는 쪽 `aim` 만 시험했다(새 앱끼리는 `aim` 이 막아서 받는 쪽이 도달하지 않는다 — 옛 앱·고친 앱만 닿는다). ④ 테스트가 ID 마다 따로 1초를 "의도"로 못 박았고, ID 하나로만 100번 보냈다. ⑤ 사진 테스트가 입자 수와 위치만 셌고 알파가 1 미만인 입자를 그린 적이 없다. ⑥ 프레임이 하나인 스프라이트로 시험해 "프레임 × 단계" 가 단계 수 이하라는 말이 늘 참이었다. ⑦ 메모리는 어떤 테스트도 세지 않는다. ⑧ 윈도 셀프테스트는 맥에서 돌지 않는다.
- **고침:** ① `turn`: 동점이면 facing 이 상대 쪽을 향할 때만 유지하고, 반대쪽이면 같은 축에서 상대 쪽으로 돈다(때림·미는 방향·스페이스 돌아서기가 같은 함수라 함께 맞는다. 등급 1 은 대각선이 닿지 않아 옛 규칙과 같다). ② `onTackleKey`: 발 앞 칸이 나무 칸이 아니고 팀원 몸이 덮으면 나무를 건너뛰고 그 팀원을 친다(옆에 선 팀원은 여전히 나무가 먼저). ③ `PlazaSnowball.trace/hitTile(…map:)`: 내 지도에서 공을 막는 첫 칸에서 nil, 그때는 `aim` 의 빗나감으로 막는 칸 앞에서 멈추게 그린다. ④ `PlazaShove.maxMovesPerWindow`(3): 모든 보낸 사람을 합쳐 1초 안에 기록된 이동이 3 번이면 거절(거절은 아무것도 적지 않으므로 표도 3 개에서 멈춘다). ⑤ `drawProps` 가 알파를 쓰고 그 뒤 1 로 되돌린다(캐릭터 사이에 섞여 그려지므로). ⑥ 단계가 바뀔 때 다른 단계의 구운 그림을 버린다. ⑦ 지금 계절 것 하나만 쥐고 창을 닫을 때 놓는다(작은 지도의 `seasonMapImage` 도 같이). 그림은 그대로이고 다시 열면 다시 굽는다. ⑧ 한 번이라도 잎이 보였는지(`mostLeaves > 0`)를 판정하고, 사진은 0.3초(프레임 78)에 찍는다.
- **부류 스윕:** 돌아서기 호출부 네 곳(C/X 돌아서기, 내 돌진, 받는 쪽 밀기, 따라 하기)은 모두 `turn(from: 때리는 쪽, to: 맞는 쪽)` 이라 같은 방향 규칙으로 맞는다. 받는 쪽이 보낸 쪽 선을 믿는 곳은 눈덩이뿐이었다(`.drag`/`.pull`/`.tackle` 은 이미 내 지도·몸으로 확인). 보낸 사람 ID 로 키를 잡은 시간 표는 `PlazaShove` 외에 `TeamNotifications` 의 확성기·게임 초대 두 개가 있으나 알림 억제일 뿐 나를 움직이지 않는다. 사진 반복문 중 알파를 쓰지 않는 것은 `items`(알파 1)·`fireworks`(알파 필드를 채우지 않는다)뿐이고 둘 다 알파 1 이 맞다. 전체 크기 그림을 계절·종류별로 쥐는 정적 캐시는 `cachedSeasonLooks`(계절 시트, 원래 모양)와 이것뿐이었다. 윈도 셀프테스트 중 판정이 `isXShown` 류인 곳은 온천 김(`isSteamShown`, 층이 실제로 그려야 켜진다)과 이 나무였다. 보고만 하고 고치지 않은 것: 나무 땅 그림자가 옆 캐릭터 발을 덮는 것(받아들임).
- **영구 캡처:** `PlazaTargetingTests.testADiagonalKeepsAFacingTowardThemAndTurnsAFacingAway`·`PlazaTackleReachTests.testThePushGoesFromTheTackler…`(옛 동점 규칙으로 되돌리면 실패), `PlazaTreeControllerTests.testABigBodyDoesNotHitTheTreeThroughATeammateOnTheFacedTile`(네 자리)·`testABigBodyStillHitsTheTreeWithATeammateOnlyBeside`, `testASnowballThrownThroughTheTreeDoesNotMoveMe`(+ 열린 길은 여전히 맞는 짝 시험), `PlazaDragTests.testManySenderIDsMoveMeAtMostThreeTimesASecond`·`testTwoFriendsTacklingInTurnAreNeverHeldByTheCap`, `PlazaWeatherTests.testAFadingPropIsNotOpaqueAndLeavesTheNextActorAlone`, `PlazaPhotoTests.testTheFadeKeepsOnlyTheCurrentStepsBakedFrames`(여섯 프레임), `PlazaSeasonTests.testTheMinimapImageHasTheTreeAndKeepsTheSnowFlag`(한 계절만 쥠·닫으면 놓음). 결함을 일부러 넣어 일곱 건 모두 실패하는 것을 확인했다(⑧은 윈도 CI 가 확인한다).
- **규칙:** 두 쪽이 같은 함수로 방향을 정하는 규칙은 동점·대각선에서 "맞는 쪽이 멀어지는가" 를 시험한다. 받는 쪽은 보낸 쪽의 직선·위치를 내 지도로 다시 확인한다. 보낸 사람 ID 로 키를 잡은 제한은 ID 를 늘려 피할 수 있으니 전체 상한을 함께 둔다. 입자에 알파 필드가 생기면 사진 반복문이 그 알파를 쓰는지 본다. 단계가 한 방향으로만 가는 캐시는 지나간 단계를 버린다. 셀프테스트 판정은 "층이 있다" 가 아니라 "일이 실제로 일어났다" 를 본다.

## 2026-11-22 — An adversarial audit of the unreleased minigame (#330) found defects only two or more Macs can show

Found before release by three independent read-only reviews (correctness, policy, design). Nothing reached teammates.

- **A Mac cut off from everyone won the game.** A laptop that slept (or lost Wi-Fi) mid-game had no teammate in sight on waking, so it was "the first player here", made itself referee, put the holder and every absent player out and published "I won". An ended game outranks a running one in the merge, so on reconnect every plaza switched to that result. *Fix:* `tick(connected:)`. With no teammate connected a Mac judges nobody; it may only put itself out (its own fuse, or after `PlazaGame.isolationLimit`), and the plaza says "연결이 끊겨 판에서 빠졌어요" instead of naming a winner.
- **Any player leaving re-dealt the bomb.** `leave` called `putOut`, which always started a new round: closing the plaza a second before the blast saved the holder, and the leaver was drawn blowing up. *Fix:* only the holder going out ends the round; anyone else is added to the out list and the fuse runs on. The plaza shows a blast only for a holder of a live bomb.
- **A silent holder with the smallest ID had no referee.** The referee was "the first player here" and the holder counted. *Fix:* the holder is never its own referee.
- **Being listed made a Mac play.** `players.contains(me)` decided it, so a late N or a made-up list locked in someone who never said yes, and anyone's presence could carry an invitation in any host's name. *Fix:* `PlazaGameEngine.isPlayer` needs my own yes (a Mac listed without it steps out quietly); an invitation is learned only from its host's own presence; a blast or a name is shown only for members whose own presence said yes.
- **Invitations could loop** (open, cancel, five seconds, open). *Fix:* `PlazaGame.reopenDelay` after a game cancelled before it started, enforced by the host's Mac and by every receiver.
- **The bounds were not closed under the engine's own moves.** A received `pass` at its limit made the next move out of bounds: dropped, learned again, moved again, five times a second. *Fix:* no pass at the limit, the explosion ends the game with no winner, and `round` may not run ahead of the out list.
- **Design:** the next holder was shown through the countdown and the pause (a head start longer than the map), and a holder ran no faster than those fleeing. *Fix:* the holder stays hidden until the bomb is live; a holder runs a `PlazaBomb.holderRunStepDuration` step.
- **Policy:** the blast shook every open plaza (watchers, people focusing) and ignored Reduce Motion; the urgent pulse ran above three a second; the last game stayed in a closed plaza's presence. *Fix:* shake on players' screens only and never under `PlatformPlaza.reduceMotion()`; `PlazaActor.bombPulseRate`; `makePresence` sends only a live game.

- **Why the tests did not stop them:** every engine test ran inside one harness where a member who is not there *neither ticks nor hears*, so a Mac that keeps ticking with nobody in sight was never simulated; the leave test covered only the holder; the silent-holder test passed because its seed happened to make "b" the holder; controller tests are two-player and call the receiving side directly, so sender-side guards never ran. The twenty faults injected before #330 were all inside rules the tests already exercised: they measured the tests, not the scenarios.
- **Class sweep:** every place one Mac decides something about another member from "who is present" (`putOut`'s sweep, the referee, the host's lock): each now runs only when connected. Every received field that names a member (`host`, `players`, `holder`, `out`, `winner`): checked against the member's own presence before it is shown.
- **Permanent capture:** `PlazaGameTests` "Leaving, cut-off Macs and consent" (the harness has a `cutOff` set: ticking, unreachable) and `PlazaGameControllerTests` "The 2026-11-22 audit".
- **Class rule:** with no server, test every rule from a Mac that sees nobody (asleep, offline) and from one that reconnects with an older or a "finished" state. A list received from a peer is a claim: before acting on "X is in", look for X's own word. A test of a tie-break or a role (referee, holder) must pin who gets the role, not accept whoever the seed picks.

## 같은 빌드인데 `settings.openCost` 프레임 수가 러너 속도에 따라 3–5 로 흔들려 main 과 PR 의 windows-app 을 막았다 (v2.5.638 준비, 2026-11-22)
- **증상:** #334 의 PR 실행 두 번과 main(5c18827c) 실행 44990471889 의 설치본 셀프테스트가 `settings.openCost` "5 frames with a paint (budget 4)" 로 실패했다. 같은 실행의 번들 셀프테스트와 직전 커밋들은 3–4 로 통과했다.
- **직접 원인:** 실패와 통과 모두 창 164 개, paint 28, erase 45 로 같은 일을 했다. 다른 것은 러너 속도뿐이다(빌드 62–91 ms 는 3–4 프레임, 112–113 ms 는 4–5 프레임). 느린 러너에서는 첫 프레임의 지우기가 두 프레임으로 갈린다. 설정 코드는 v2.5.637 이후 바뀌지 않았다.
- **왜 못 걸렀나:** 예산 4 는 관측 범위(3–4)의 가장자리였고, 프레임 수는 일의 양이 아니라 시간에 따라 달라지는 값인데 그것 하나로 페이지 크기를 지키게 했다. v2.5.636 때 같은 증상을 두 번 겪고도 예산과 측정 방식을 그대로 뒀다.
- **부류 스윕:** `popover.swapCost` 의 Back·Recap·Collection 은 같은 실행들에서 여유가 있어(창 48 개 안팎) 그대로 둔다. 시간에 따라 달라지는 값만으로 막는 다른 셀프테스트 예산은 찾지 못했다.
- **고침:** 설정 전환의 프레임 예산을 5 로 올리고, 창 수 예산 164 를 더했다. 행을 하나 더하면(v2.5.636 의 결함) 러너 속도와 무관하게 창 수에서 걸린다.
- **영구 캡처:** `settings.openCost` 의 창 수 예산(Windows CI 의 셀프테스트). 맥에서는 돌지 않는 코드라 CI 실행으로 확인한다.
- **규칙:** 셀프테스트 예산은 같은 빌드에서 값이 변하지 않는 수(창 수, 메시지 수)에 건다. 시간에 따라 달라지는 수(프레임, ms)는 관측 범위에서 한 단계 이상 여유를 둔다.

## 포춘쿠키 가판대: 구버전 팀원이 쉼터로 튀고, 깨는 중 Space 가 쿠키를 지우고, 받는 길과 문구 순서에 테스트가 없었다 (#340 감사, 2026-11-23)
- **증상:** ① 2.5.638 이하 팀원이 가판대 칸(그 버전에서는 풀밭, 아이템도 놓인다)에 서면 새 버전 화면에서 쉼터로 순간이동해 그려졌다. ② 쿠키가 떠 있는 7초쯤 안에 Space 를 다시 누르면 내 화면에서 쿠키가 사라지고 쪽지만 다시 펴졌다(팀원 화면은 정상). ③ 달력이 그레고리력이 아닌 기기는 광장의 날 키(`PlazaActivity.dayKey`)가 그 달력의 숫자로 나왔다: 팀원과 키가 달라 "오늘 광장" 이 안 보이고, 윤달이 있는 달력은 한 달 떨어진 두 날이 같은 키가 된다(추정, 실기기 확인 없음).
- **직접 원인:** ① `PlazaScene.resolvedTile` 은 걸을 수 있는 칸·물·큰 나무만 받는다. 새로 막은 칸 종류(`.stall`)를 더하면서 이 목록을 보지 않았다. ② `openFortune` 이 첫 호출에서 날을 저장하고, 두 번째 호출은 "같은 날 다시 보기" 길로 가 상태를 쪽지만 있는 것으로 덮어썼다. ③ 키를 `Calendar.current` 의 연·월·일로 만들었다.
- **왜 못 걸렀나:** ① #327 이 큰 나무에서 같은 일을 고치고 테스트(`testAnOldPeerOnTheTrunkIsDrawnThere`)도 남겼지만, 그 테스트는 나무 칸만 본다: "막힌 칸을 새로 만들면 구버전이 그 위에 선다" 는 규칙은 기록에 없었다. ② 테스트가 쪽지가 사라진 뒤(9초 뒤)에만 두 번째 Space 를 눌렀다. ③ v2.5.637 감사가 "동등 비교만 쓰면 음력 키도 된다" 고 받아들였는데, 키가 팀원에게 전해져 비교된다는 점과 윤달은 보지 않았다. 그리고 `TeamRuntime` 의 `.fortune` 분기는 어떤 테스트도 밟지 않았다: 컨트롤러 테스트는 `showFortune` 을 직접 부르거나 `onEmote` 를 갈아끼워서, 분기를 지워도 전부 통과했다. 문구 번호는 전송값인데 순서를 고정한 테스트가 없었다.
- **고침:** ① `resolvedTile` 이 가판대 칸도 그 자리에 그린다(`PlazaMap.isStall`). ② 쪽지가 떠 있는 동안 `openFortune` 은 아무것도 하지 않는다. ③ `PlazaActivity.dayKey` 가 `DayBoundary.dayKey`(그레고리력)를 쓴다. 호출부 전부(활동, 나무, 포춘쿠키, 카드, 목록)가 한 번에 바뀐다.
- **부류 스윕:** 받은 칸을 그리는 다른 길은 `applyDitto` 하나다(걸을 수 있는지 보지 않고 그 칸에 그린다: 구버전이 띄운 메타몽은 가판대 위에 그려지고, 이제 팀원과 같은 처리다). 감사가 낸 "자정에 안내가 안 바뀐다" 는 사실이 아니었다: 1초 틱의 `refreshCampfire` 가 안내를 다시 그린다(가드를 넣었다가, 빼도 테스트가 통과해서 알았고 가드는 뺐다. 기존 테스트의 "저절로는 안 바뀐다" 주석이 틀렸다).
- **영구 캡처:** `PlazaTreeLayerTests.testAnOldPeerOnTheStallIsDrawnThere`, `PlazaFortuneControllerTests.testSpaceDuringTheCrackLeavesItAlone`, `TeamRuntimeTests.testAReceivedFortuneShowsTheSlipAndABadOneShowsNothing`(실제 받기 경로), `PlazaFortuneTests.testTheFirstLinesAndActionsKeepTheirNumbers`(앞 300줄·12행동의 해시. 배포 전에 80줄에서 200줄로 늘렸다), `PlazaFortuneTests.testTheDayKeyIsGregorianOnAnyCalendar`, `testANewDayBringsANewCookie`(틱으로 자정을 넘긴다). 각 고침을 되돌리면 해당 테스트가 실패하는 것을 확인했다.
- **규칙:** 지도에 막힌 칸 종류를 새로 만들면 `resolvedTile` 에 더한다: 이전 버전 팀원은 그 칸에 설 수 있다. 팀원에게 전해지는 날 키는 그레고리력으로 만든다. 받은 이모트의 새 분기는 `TeamRuntimeTests` 에서 실제 전송으로 밟는다. 감사 지적도 고치기 전에 재현부터 한다.

## 연달아 맞아도 처음 한 번만 밀렸다: 받는 쪽 쿨다운 1초가 보내는 쪽 0.3초보다 길었다 (v2.5.637–638, 2026-11-23 사용자 리포트)
- **증상:** 몸통박치기나 던지기를 연달아 맞으면 처음에만 밀리고 2타·3타는 충격 별만 보이고 밀리지 않았다. v2.5.636 까지는 맞는 대로 밀렸다.
- **직접 원인:** 끌어당기기 PR(#324)이 받는 쪽 쿨다운 `PlazaShove.receiveCooldown` 을 1초로 넣었다. 보내는 쪽은 0.3초마다 칠 수 있어서(`emoteInterval`) 정직한 연타 네 번 중 세 번이 버려졌다. 쿨다운을 두는 것은 사용자 결정이었고(고친 앱의 연타를 받는 쪽에서 막는다), 1초라는 값과 눈덩이·물귀신까지 넓힌 것은 설계자 판단이었다.
- **왜 못 걸렀나:** 명세가 값을 "설계자 판단·미확인" 이라고 표시했지만 사용자에게 따로 묻지 않고 배포했고, PR 본문의 "확인할 설계" 목록에만 적었다. 테스트는 1초를 의도로 못 박았다(`testTwoTacklesFromOneTeammateUnderASecondApartPushMeOnce`). 받는 쪽 값을 보내는 쪽이 정직하게 낼 수 있는 간격과 견줘 본 테스트가 없었다.
- **고침:** `receiveCooldown` 을 0.125초로 줄였다(보내는 쪽 0.3초보다 짧다). 정직한 연타는 맞는 대로 다 움직이고, 그보다 빨리 보내는 고친 앱만 걸린다. 전체 상한(`maxMovesPerWindow` 3번)은 같은 시간 창을 쓰므로 함께 0.125초에 세 번이 됐다.
- **부류 스윕:** 소스에 남은 "설계자 판단·미확인" 상수 다섯 개(몸 크기 등급, 온천 붉은색·섞는 정도, 김 개수, 낙엽 개수)는 모양만 정하고 사용자의 행동을 거절하지 않는다. 받는 쪽에서 행동을 거절하는 다른 시간 규칙(놀람 3초, 단체 사진 2초, 게임 다시 열기, 복사본 장난 60초)은 `TEAM.md` 에 적혀 있고, 정직한 연타를 받는 규칙이 아니다.
- **영구 캡처:** `PlazaDragControllerTests.testThreeTacklesInARowFromOneTeammatePushMeThreeTimes`(쿨다운이 `emoteInterval` 보다 짧다는 단언과, 0.3초 간격 세 번이 세 번 다 민다)·`testThreeSnowballsInARowFromOneTeammatePushMeThreeTimes`. 값을 1초로 되돌리면 실패한다. 기존 쿨다운 테스트는 시간을 `receiveCooldown` 의 배수로 써서 값이 바뀌어도 규칙을 지킨다.
- **규칙:** 사용자가 하던 행동을 거절할 수 있는 값(쿨다운, 상한)은 "미확인" 인 채로 배포하지 않는다: 넣기 전에 값을 묻는다. 받는 쪽 제한은 보내는 쪽이 정직하게 낼 수 있는 가장 빠른 간격보다 짧아야 하고, 그 간격으로 연타하는 테스트를 함께 둔다.

## 윈도 셀프테스트가 사용자 PC 를 건드릴 수 있었다 + 창 메시지 파라미터·단일 인스턴스·크래시 표식 (윈도 감사 F1–F7, 2026-11-24)
- **증상(감사):** ① 러너 전용 점검(고대비 전환, SendInput, 클립보드, 키보드 배치, Run 키, 팀 가입)이 "`CI` 환경변수가 있으면" 열렸다 — 사용자 셸에 `CI` 가 있으면 사용자 PC 에서 돌았다. ② `--selftest` 가 `PTB_STATE_DIR` 없이 사용자의 진짜 `companion-state.json` 을 갱신할 수 있었다. ③ `--selftest-out <폴더>` 가 폴더를 통째로 지웠다. ④ 사용자 PC 의 팀 점검이 LAN 에 열고 mDNS 로 광고했고, `limits.claude` 가 고정 토큰을 Anthropic 에 보냈다. ⑤ `Int(wParam)` 류 변환과 검증 없는 lParam 포인터 읽기(같은 사용자의 다른 프로세스가 아무 값이나 보낼 수 있다). ⑥ 단일 인스턴스가 창의 프로세스를 확인하지 않고 `AllowSetForegroundWindow`·`PostMessageW` 를 했고, 뮤텍스를 다른 프로그램이 쥐고 있으면 말없이 끝났다. ⑦ 크래시 표식·로그가 상태 폴더와 무관한 한 이름이라 나란히 도는 두 인스턴스가 서로 것을 지우고 "비정상 종료" 를 거짓 보고했다.
- **직접 원인:** ① 게이트의 정의가 "러너인가" 가 아니라 "`CI` 가 있는가" 였다(`onCI` 로 모은 것이 2026-11-15 `8d35ec34`, 사용자 PC 에서 막는 스캔이 2026-11-19 `12464933`). 사용자 셸의 `CI` 는 흔하다. ② 설정은 셀프테스트 전용 suite 로 보냈지만 상태 파일(저장·팀 피드)은 기본 폴더였다. ③ `removeItem` 은 폴더도 지운다. ⑦ 표식 이름을 상수로 두었고 뮤텍스와 달리 상태 폴더 해시를 쓰지 않았다.
- **왜 못 걸렀나 (테스트·리뷰 공백):** 고대비 점검은 2026-11-17 에 시스템 값 두 개만 되돌려서(테마가 바꾸는 다른 Personalize 값은 그대로) 연쇄 결함을 만들어 제거됐고, 2026-11-19 에 다크 메뉴 점검(`popover.darkMenu.highContrast`)을 위해 "CI 에서만 + 두 값 복원" 으로 되돌아왔다. 2026-11-17 규칙("바꾼 값 *전부*(연쇄 포함)를 저장·복원")이 같은 날 항목에 있었는데 되돌릴 때 지켜지지 않았다 — 재도입은 `8bcbf2ab`(다크 메뉴)이고 `11c9efe3` 은 게이트만 걸었다. 둘 다 복원 값을 두 개로 남겼다. 주입한 판정(`popover.darkMenu.mode`)은 결정만 증명하고 실제 테마 아래의 메뉴 픽셀은 증명하지 못해서 실제 전환이 필요했다. `off_ci_selftest` 입력은 `CI` 를 *지워서* 돌렸기 때문에 "CI 가 있는데 러너가 아닌" 경로(= 사용자 셸)를 한 번도 밟지 않았고, 스냅샷은 상태 파일·팀 포트를 보지 않았다. 스캔 테스트는 호출이 `onCI` 를 참조하는지만 보고 `onCI` 의 정의는 보지 않았다. `Int(wParam)` 은 #270 에서 같은 부류를 겪고 "`Platform/Windows/**` 전수" 를 했지만 `Int(wParam)` 문자열만 훑었고 막는 테스트는 만들지 않았다.
- **고침:** ① 러너 게이트 = `PTB_SELFTEST_RUNNER=1`(두 워크플로가 설정, `onCI` 이름은 스캔이 키로 쓰므로 유지). 고대비 점검은 Personalize 의 *모든* 값을 타입째 저장해 복원하고, 같은 값으로 돌아왔는지 직접 확인하며 실패하면 점검이 실패한다. ② 러너가 아니고 `PTB_STATE_DIR` 도 없으면 임시 상태 폴더(종료 때 삭제). ③ `SelftestOutputTarget`: 일반 파일만 지우고 폴더는 종료 코드 2. ④ 사용자 PC 의 팀 멤버는 `::1` 만 열고 광고하지 않으며 `connect(to:)` 로 잇고, `limits.claude` 는 건너뛴다. ⑤ `Int(truncatingIfNeeded:)`, `WinMessagePointer.readable`(VirtualQuery 로 읽을 수 있는 구간인지 확인) — `WM_DPICHANGED`·`WM_NOTIFY`·`WM_POWERBROADCAST` 의 lParam. ⑥ 창의 프로세스 이미지 경로가 이 실행 파일일 때만 `AllowSetForegroundWindow`·메시지를 보내고, 아니면(또는 창이 없으면) 메시지 상자로 알린다(`--autostart` 는 조용히). ⑦ 표식·로그 이름에 상태 폴더 접미사(`WinSingleInstance.stateSuffix`).
- **부류 스윕:** `Platform/Windows/**` 의 `Int/UInt32/DWORD/…(wParam|lParam)` 전수 — 고친 곳 외에는 마스크·`bitPattern` 으로 이미 안전. `environment["CI"]` 는 `WindowsSelftestUpdate`·`WindowsUpdateInstaller` 에 남아 있지만 명시 플래그(`--selftest-update-from`)와 설치 레이아웃이 함께 있어야 열린다(`--selftest` 가 아님): 건드리지 않았다. 임시 상태 폴더는 `--selftest` 인자일 때만 만든다: 다른 `--selftest-*` 진입점(크래시·광장·넷버스트 등)이 기본 상태 폴더에 쓰는지는 이번에 확인하지 못했다(미확인).
- **고치다 겪은 것:** F2 의 임시 상태 폴더는 앱의 팀 설정을 `ptb.team.<폴더 해시>.plist`(+`.bak`)로 진짜 설정 옆에 만들었고, `off_ci_selftest` 의 스냅샷(`settingsFiles`)이 첫 실행에서 잡았다. 종료 때 `WindowsSelftest.removeTemporaryState` 가 그 두 파일도 지운다(해시는 일회용 폴더의 것이라 그 실행의 파일뿐).
- **영구 캡처:** `WindowsMessageParameterScanTests`(트랩하는 변환이 추가되면 실패, 스캔 자체도 양·음 입력으로 시험), `SelftestUserPCSafetyScanTests.testTheRunnerGroupKeysOnTheRunnerFlagAndTheWorkflowsSetIt`(`onCI` 정의와 워크플로의 변수), `SelftestOutputTargetTests`(폴더 보존), `WindowsCrashLogTests.testTwoInstancesKeepSeparateMarkersAndCrashLogs`, 윈도 셀프테스트 `singleInstance.foreignHolder`, `team.loopbackExchange`, `off_ci_selftest` 실행(`CI` 는 두고 러너 변수·`PTB_STATE_DIR` 만 지움 + 상태 파일·설정 파일·크래시 로그 스냅샷; 수동 실행 전용이라 자동으로 돌지 않는다: 병합 전에 한 번 돌려야 한다), `selftest.mode`(`run-selftest.ps1` 이 러너 변수가 있으면 `runner` 를 요구한다), `LiveFetchForbiddenTests`.
- **사용자 PC 의 임시 폴더가 만든 부작용 (리뷰):** ① 임시 상태 폴더의 해시로 팀 설정 suite(`ptb.team.<해시>`)가 따로 만들어져 진짜 설정 옆에 `.plist`/`.bak` 이 남았다 → 셀프테스트는 팀 설정도 자기 suite 에 둔다(`teamDefaults`). 크래시 로그(`PokeTokenBar-<해시>.crash.log`, 필터가 열어 둔다)와 표식은 `removeTemporaryState` 가 지운다. ② 임시 폴더 덕분에 단일 인스턴스 이름이 달라져 사용자의 셀프테스트는 실행 중인 앱에 양보(종료 코드 3)하지 않고 함께 돌며 `PokeTokenBar.log` 를 같이 쓴다(TEAM.md 에 적음). 로그 정리(`trimStderrLog`)는 `--selftest` 에서 하지 않는다. ③ 사용자 PC 의 셀프테스트는 `store.refresh()` 의 한도 조회로 진짜 `~/.claude/.credentials.json` 을 읽고 Anthropic 에 보냈다 → `AppEnv.liveFetchForbidden`(게이트를 닫음)과 스텁 프로바이더 유지. ④ 창 메시지 마스크: `& 0xFFFF` 가 있다고 안전한 게 아니다(`Int16(lParam & 0xFFFF)` 는 0x8000 에서 트랩) → 스캔이 대상 타입에 맞는 마스크만 받는다. ⑥ 재검토: 한도 조회 공급자 중 Cursor·OpenCode Go·Grok 은 토큰을 읽은 뒤에야 게이트에 닿았고, Codex 는 CLI 를 띄우며, 상태 페이지 공급자는 게이트가 없어 `store.refresh()` 가 사용자 PC 에서 status.claude.com·status.openai.com 에 GET 했다 → 각 `fetch` 맨 위와 `SessionKeyLimitsProvider.credential()` 이 `AppEnv.liveFetchForbidden` 을 먼저 본다(`LiveFetchForbiddenTests`: 가짜 키·토큰 원천에 호출 횟수를 세어 0 을 확인; Cursor·Codex·세션 키는 가짜 원천을 넣을 수 없어 소스에 확인문이 있는지만 본다. 가드를 뺀 채 돌리는 주입 시험은 진짜 로그인 저장소를 읽게 되어 하지 않았다). 게이트는 `--selftest` 만이 아니라 모든 `--selftest*` 프로세스(자식 포함)에서 닫는다. 자식 모드: `-second`(두 번째 시작), `-popover-helper`, `-crash`, `-defaults-reader/-writer`, `-guard-reader`, `-dialog-exit`, `-menu-exit`, `-exit-stuck`, `-balloon`, `-net-burst`, `-park`, `-plaza-placement`, `-waker-hunt`. 셀프테스트가 띄운 자식은 부모의 `PTB_STATE_DIR`(임시 폴더)을 물려받는다. 사람이 손으로 자식 모드만 실행하면 기본 상태 폴더를 쓰는데, 각 모드가 거기에 무엇을 쓰는지는 추적하지 못했다(문서화된 사용법이 아님). ⑧ 세 번째 재검토: Cursor 의 사용량 경로(`CursorUsageAPI.fetchEntries`)도 `state.vscdb` 토큰을 읽어 Cursor 서버에 보냈다 — 공급자를 하나씩 막는 방식이 두 번 틀렸다(Cursor 한도, 그다음 Cursor 사용량). 그래서 한 곳에서 막는다: 요청은 `PlatformCompat.oneShotData`/`oneShotDownload` 의 `AppEnv.fetchBlock`(루프백·`.invalid`/`.test` 와 `exempting` 한 호스트만 통과), 로그인 읽기는 각 읽는 함수(`CursorAuthentication.current/refresh`, `openCodeAPIKey`, Grok `accessToken`, `PlatformCompat.readSecret`, Claude OAuth 토큰 캐시), 프로그램 실행은 `ProcessRunner` 두 진입점. 사용자 PC 의 스토어는 Cursor 공급자를 목록에서도 뺀다. `testEveryRequestOrLaunchSiteIsAccountedFor` 가 요청·실행 기본 호출(`URLSession…data`, `Process()`, `CreateProcessW`, `WinHTTPFetch.data`)을 가진 파일을 전수로 대조해서, 새 파일이 생기면 이유를 적기 전엔 실패한다. 진짜 호스트에 닿는 점검 둘(`graphql.pokeapi.co`, `script.google.com`)만 `beginExemption`/`endExemption` 으로 그 호출 동안만 열린다.
⑦ 메시지 상자의 홀더 경로는 제어 문자를 빼고 200자로 자른다.
⑤ F5 의 메시지 규칙은 Windows 가 마샬링하지 않는 메시지(`WM_NOTIFY`, `WM_APP+`)에 적용한다: `WM_GETMINMAXINFO` 같은 시스템이 보내는 메시지의 포인터는 시스템이 채운 것이다.
- **규칙:** 사용자 PC 에서 막을 것의 게이트는 환경에 *있을 수 있는* 변수가 아니라 우리 워크플로만 설정하는 변수에 건다. 시스템 값을 바꾸는 점검을 되살릴 땐 이 로그의 2026-11-17 항목을 먼저 읽는다. `--selftest` 는 사용자의 진짜 폴더·LAN·외부 서버에 닿지 않는다. 메시지 파라미터는 `truncatingIfNeeded`/`bitPattern`, lParam 포인터는 `WinMessagePointer.readable` 뒤에만 읽는다.

## 로컬 파일 감사(v2.5.640): 합계는 트랩하고, 숫자 시각은 창이 없고, 못 읽은 세이브가 빈 상태로 교체됐다 (2026-11-24)
- **증상:** ① 로그 항목 2,306 개가 모이면 토큰 합계가 Int64 를 넘어 트랩했다(항목당 상한 1e15). 파일이 디스크에 남아 매 새로고침·재기동마다 죽는다. ② Kimi `time: 1e19`·Pi/Grok/OpenCode/Aside 의 거대한 숫자 시각이 `Int64(millis)`·`Int(date)`(블록 id)에서 트랩했다. ③ 존재하지만 읽지 못하는 세이브(Windows 공유 위반·백신·EACCES)를 "신규 설치"로 읽어 첫 새로고침이 빈 상태로 덮었다. `.corrupt` 이동이 실패해도 같았다. ④ 작업 폴더 안 `y.jsonl -> /dev/zero` 심볼릭 링크를 `readToEnd()` 가 따라가 메모리가 끝없이 늘었다. ⑤ 인벤토리 개수 `Int.max` 가 다음 `+=` 에서 트랩했고, 사탕 지급은 `candyGrantTier` 저장 전에 죽어 재기동마다 반복됐다. ⑥ 봉투를 `SaveTransfer.decode` 가 거절하면(새 스키마·8 MB 초과) 레거시 폴백이 봉투를 빈 `CompanionState` 로 읽어 스냅샷 복구가 빈 상태를 설치했다. ⑦ 미래 날짜 스냅샷이 "가장 최신"이 되어 자동 스냅샷이 멈추고 복구가 그것을 골랐다. ⑧ Pi·omp·omo·Kimi 가 파일 전체를 `String` 으로 올렸다. ⑨ Mac 가져오기가 크기 확인 전에 파일을 다 읽었다. ⑩ `refreshInterval` 에 `0.01` 을 쓰면 10 ms 마다 전체 스캔이 돌았다.
- **직접 원인:** 합산 지점이 항목 수를 안 보고 `+`/`+=` 를 썼다(추출기마다 클램프하면 합은 안전하다고 가정). 숫자 시각은 `Double` 이 유한하면 `Date` 를 만들었다(Antigravity 만 창이 있었다). 세이브 읽기는 "읽기 실패 = 파일 없음" 으로 접었다. 열거는 링크된 *디렉터리*만 따라가지 않고 링크된 *파일*은 돌려줬다. 레거시 폴백은 "디코드 성공 = 세이브" 로 봤다(`CompanionState` 는 전 필드 관대 디코딩이라 어떤 JSON 이든 성공한다). 최신 스냅샷 판정이 `now` 와의 선후를 안 봤다.
- **왜 못 걸렀나:** 오버플로 테스트는 전부 **항목 하나**를 클램프하는지만 봤고(`testCursorHuge…`·`testHermesHuge…`), 클램프된 항목 수천 개를 더하는 경로가 없었다. 시각 방어는 Antigravity 에만 있어 다른 읽기가 같은 부류라는 걸 아무도 안 이었다. 세이브 테스트는 "없음/손상/정상" 셋뿐이고 "있지만 못 읽음"(권한)을 만든 적이 없다. 링크 테스트는 없었고, 스냅샷 테스트는 봉투 거절을 만들지 않았으며 시각은 항상 과거였다.
- **고침:** `Int.saturatingAdding`/`saturatingSum`(Models.swift)을 `Bucket`·`Entry.total`·`PeriodUsage`·`UsageStore`(오늘·주·월·일별 병합)·`UsageRecap`·`CompanionStore`(오늘 합·원장 델타·`usedSinceInstall`·`eggUsage`·`usedAtStage`)·인벤토리 세 곳에 쓰고, 요청 단위 항목 상한 `maxParsedTokenValue` 를 1e10 으로 낮췄다. **세션 합계를 한 항목에 담는 소스(Hermes `sessions` 행)는 별도 상한 `maxParsedSessionTotalValue`(1e12)** — 캐시 읽기가 큰 정상 세션이 1e10 으로 잘리면 사용량이 줄어든다. `LocalUsageReader.plausibleDate(epochSeconds:)`(Antigravity 와 같은 2001-09 ~ 2100-01 창)를 숫자 시각을 읽는 곳(Kimi·Pi·Grok·OpenCode 계열 `dateValue`·Aside·`CursorUsageAPI.epochDate`·`ClaudeAccountUsage.promptDate`)에 쓰고, 블록 id 는 범위 밖이면 0. `CompanionStore.load` 는 "파일 없음"과 "있지만 못 읽음"을 나눠 짧게 재시도한 뒤 못 읽으면 `persistenceBlocked`(디스크 쓰기만 끈다. 메모리 쪽 효과인 아이콘·알림은 그대로. `SettingsPlistGuard.leftAlone` 과 같은 규칙), 못 읽은 동안 들고 있는 빈 자리표시 상태(`statePlaceholder`)는 스냅샷으로 남기지 않는다(보존 한도가 진짜 스냅샷을 밀어내고 빈 상태가 최신 복구 후보가 된다). 스냅샷에서 복구한 진짜 상태는 막지 않는다. 못 읽던 세이브는 새로고침(`update()`)마다 한 번 다시 읽어 보고, 읽히면 받아들여 저장을 되살린다(UI·문구 없음, AppLog 한 줄). 받아들일 때는 세이브 불러오기와 같은 무효화(`invalidateInFlightWork`: 세대 증가·`currentLine`·연출·피드백 비움, 자리표시 시절의 부화 잠금 해제)와 라인·프로필 로드를 하고, init 이 자리표시에서 못 한 난이도 재산정을 한 번 적용하며, 읽혔지만 디코드되지 않으면 기동과 같은 처리(`.corrupt` 이동 + 스냅샷 복구, `handleUndecodableSave`)를 한다. `.corrupt` 이동 실패도 같다. 파일 읽기: `isPlainLogFile`(일반 파일·비링크)로 `collect`·`jsonlFiles`·Kiro·Codex 열거를 거르고(캐시에 이미 있는 파일이 잠깐 링크로 바뀌면 캐시된 값은 유지), `openLogHandle` 이 `O_NOFOLLOW|O_CLOEXEC` 로 연다(Windows 는 일반 열기, `PlatformCompat`). 읽기 상한 `maxLogReadBytes`(2 GiB)는 **Claude 증분 리더에만** 있다: 넘으면 거기까지 읽고 캐시가 **도달한 오프셋**을 저장해 다음 새로고침이 이어 읽는다(예전 초안은 전체 크기를 저장해 나머지를 영원히 안 읽었다). 청크 스트림 리더(Codex·Pi·omp·omo·Kimi)는 메모리가 이미 청크로 묶여 있어 상한이 없다: 21 GiB 롤아웃도 끝까지 센다. `outputs/`·`uploads/` 가지치기는 위 "이름 기반 가지치기" 회귀 때문에 **하지 않았다.** `SaveTransfer.sanitized` 가 인벤토리를 클램프한다(키는 유지). 스냅샷 레거시 폴백은 `format` 키가 없을 때만이다. 복구는 `now` 이전 후보를 먼저, 미래 날짜는 뒤에 시도하되 미래 날짜 쪽의 `lifetimeTokens` 가 더 크면 그것을 먼저 써서 가장 진행이 많은 스냅샷이 양방향에서 이긴다. `autoSnapshotIfNeeded` 는 미래 날짜를 "최신"으로 안 친다. Pi·omp·omo·Kimi 는 `forEachCodexLine` 위의 `forEachLine` 으로 청크 읽기(CRLF 도 LF 와 같은 결과). Mac 가져오기는 `SaveImportTool.readSave`. `refreshInterval` 은 0(수동) 외에 30 s ~ 1 h 로 클램프, 없거나 비정상이면 120.
- **부류 스윕:** 토큰 합산은 전수 확인했지만 **모두 포화로 바꾼 것은 아니다.** 일반 `+` 로 남은 곳과 이유: `PokemonProfile.baseStatTotal`·`PokemonForm`/`CompanionStore` 가중치 합(작은 카탈로그 상수), `reconstructedGrowthTokens`(항마다 `maxTokenValue` 로 클램프한 값 몇 개), `UsageStore` 의 분당 토큰 합(`Double`), Kiro `kiroJSONValueByteLength`(바이트 길이, 파일 크기 안), 비용 합(`Double`)은 오버플로할 수 없다. 숫자 에포크를 `Date(timeIntervalSince1970:)` 로 만드는 읽기는 위 목록 전부 창을 지난다(ISO 문자열 시각은 파서가 범위를 제한해 해당 없음). 로그를 `FileHandle(forReadingFrom:)` 로 여는 증분·청크 읽기는 `openLogHandle` 로 옮겼다. **파일 전체를 읽는 채로 남은 곳(의도적 보류):** Gemini(`parseGeminiFile`)·Grok(`parseGrokFile`)·Kiro 두 곳(`String(contentsOf:)`). `ClaudeAccountUsage` 의 `history.jsonl` 은 `~/.claude` 고정 경로라 작업 폴더 링크 경로가 아니어서 건드리지 않았다.
- **영구 캡처:** `AuditCoreFixesTests`(합계 포화·`Entry.total`·항목 상한·`plausibleDate`·Kimi 1e300·Cursor `epochDate`·블록 id·못 읽은 세이브·자리표시 스냅샷 금지·늦게 읽힌 세이브 수용·`.corrupt` 이동 실패(원본 불변, 복구된 상태는 스냅샷 계속)·늦게 읽힌 세이브가 자리표시 시절의 부화에 덮이지 않음(`CompanionStoreTests.testAdoptedSave…`)·난이도 재산정 재적용·늦게 읽힌 손상 파일 복구·인벤토리 클램프·봉투 폴백(올바른 format id + 높은 `schema` 라는 실제 트리거)·미래 날짜 복구(양방향)/자동 스냅샷·캐시 `collect` 와 Codex 열거의 링크 파일·`O_NOFOLLOW`·읽기 상한 이어 읽기(작은 상한을 주입해 큰 파일이 여러 새로고침에 걸쳐 전부 세어짐)·CRLF·`refreshInterval`)와 `LocalAdditionalUsageTests.testHermesLegitimateLargeSessionTotalIsNotClamped`. 결함을 하나씩 일부러 주입해 실패(또는 트랩)하는 것을 확인했다. 주입으로 확인하지 못한 것: `O_CLOEXEC`, `save()` 의 가드 위치(메모리 효과가 가드 위에 있다), CRLF 테스트(읽기가 이미 같은 결과라 특성 테스트다). `UsageStoreTimerTests` 는 하한을 낮춰 짧은 주기를 쓴다.
- **규칙:** 항목별 클램프는 합계의 안전을 보장하지 않는다 — 합산 지점이 포화 덧셈이어야 하고, 합산 테스트는 클램프된 항목을 **많이** 더한다. 상한은 그 항목이 무엇을 담는지(요청 하나인가 세션 합계인가)에 맞춘다. 외부 숫자 시각은 한 곳의 창을 지난다. "읽지 못함"과 "없음"을 같은 분기로 접지 않는다(저장 파일은 읽지 못하면 그 세션 디스크 쓰기를 끄되 메모리 상태와 복구 경로는 막지 않고, 다시 읽어 본다). 읽기 상한은 "넘으면 버린다"가 아니라 "넘으면 거기까지 읽고 이어 읽는다"여야 하고, 캐시는 읽은 만큼만 읽었다고 기록한다. 이미 청크로 메모리가 묶인 읽기에는 상한을 더하지 않는다(데이터만 버린다). 파일을 읽는 열거는 일반 파일만 돌려주고 열 때 링크를 따라가지 않는다. 도달 불가한 가드는 만들지 않는다: 복구 후보 순회의 "읽지 못한 후보 건너뛰기"는 목록 단계가 이미 같은 디코드로 거르므로(목록에 오른 것은 로드도 된다) 별도 테스트를 두지 않았다.

## 회사 사용량 시트: 받는 양에 상한이 없었고, 같은 키를 다시 보내면 매 행을 다시 썼고, 수식 문자가 CSV 로 나갔다 (v2.5.640 감사, 2026-11-24)
- **증상:** 웹 앱 주소와 토큰이 공개라서 누구든 새 멤버 ID·새 도구 이름·새 팀 ID 로 보고를 계속 보내 `원본` 을 셀 상한(천만 셀)까지 채우거나, 같은 1,984개 키를 반복해 락 안에서 행마다 `setValues` 를 돌려 진짜 보고를 20초 대기 뒤 실패시킬 수 있었다. 닉네임·팀 이름·플랜이 `=` `+` `-` `@` 로 시작하면 시트 안에서는 텍스트지만 CSV 로 내려받아 열 때 수식이 됐다. README 호스트 목록에는 Windows 업데이트 다운로드 호스트가 없었고, TEAM.md 는 해시를 "되돌릴 수 없다" 고 썼다.
- **직접 원인:** 검증은 요청 하나 안의 크기만 봤고 시트 전체의 양은 보지 않았다. `upsertRows` 는 키 4열만 읽고 13열 행을 만들어 비교해서(`rowsEqual` 은 길이부터 다르면 거짓) 이미 있는 키가 전부 "바뀜" 이 됐고, 받은시각 열도 매번 달랐다. 수식 문자는 `asText` 의 `'` 접두어(저장 표식, CSV 에는 안 남음)에만 기댔다.
- **왜 못 걸렀나:** 테스트가 "같은 키를 다시 보내면 숫자가 제자리에 덮어써진다" 만 봤고 쓰기 횟수는 세지 않았다: 불필요한 쓰기도 결과 행은 같아서 통과했다. 한도 테스트는 정직한 크기만 썼고 한도 위로 쏟아 붓는 요청이 없었다. 수식 테스트는 시트 셀이 텍스트인지만 봤고 내보내기 결과는 보지 않았다. 설계서가 "가짜 행은 받아들인다" 고 정한 전제(미지정 격리)가 부서 이름 규칙이 바뀌며 무너진 것을 한도 쪽에서 다시 보지 않았다.
- **부류 스윕:** 외부 입력이 시트를 키우는 길은 `원본`, `한도`, `기기`(새 멤버)와 그에 딸린 `부서`·`팀이름`·`사람` 이다. (1차 감사에서는 뒤의 셋이 "새 행마다 원본 행이 따라오므로 원본 상한이 막는다" 고 적었으나 틀렸다: 이미 있는 날짜 키를 팀 ID 만 바꿔 다시 보내면 원본 행은 늘지 않고 `부서`·`팀이름` 행만 요청마다 약 60개 늘고, 한도 16개의 팀을 바꿔 보내면 `부서` 행이 늘었다. 리뷰 프로브: 멤버 1명, 요청 50번에 부서 3152행. 2차에서 이 둘에도 시간·총 상한을 걸었다.) 도구 이름은 `parseTool`·`parseLimit` 두 곳이라 둘 다 허용 목록으로 바꿨다. 클라이언트 문자열을 쓰는 곳은 닉네임, 팀 이름, 플랜 셋이다(도구·계정·도메인은 정규식이 괄호와 공백을 막아 수식이 될 수 없다).
- **고침:** 허용 도구 목록, 멤버·원본 행·한도 행의 시간당·총 상한(`src/00_config.js` 의 이름 붙은 상수, `rate_limited`/`sheet_full`), 같은 값이면 쓰지 않는 비교(받은시각 제외, 부딪힌 행만 이어 읽음), 맨 앞 수식 문자를 전각 문자로 바꾸는 파싱, 메뉴의 멤버 ID·팀 ID 기록 지우기.
- **영구 캡처:** `store.test.js` 의 재전송 쓰기 0회·상한별 쏟아붓기·정직한 최대(21일 × 16도구)·수식 문자 테스트, 허용 목록이 Swift 의 프로바이더 ID 를 모두 덮는지 읽어 보는 테스트, `admin.test.js` 의 지우기 테스트. 가드마다 일부러 되돌려 해당 테스트가 실패하는 것을 확인했다.
- **규칙:** 공개 주소로 받는 쓰기 경로에는 요청당 상한 말고 시간당·총 상한을 둔다. 정직한 최대를 통과시키는 테스트와 상한을 넘기는 테스트를 한 쌍으로 쓰고, 거절은 보내는 쪽이 "나중에 다시" 로 다루는 코드로 답한다. "같은 값을 다시 보낸다" 테스트는 결과뿐 아니라 쓰기 횟수도 센다. 앱에 새 프로바이더 ID 를 더하면 `ALLOWED_TOOLS` 에도 더한다(허용 목록 테스트가 Swift 쪽 선언을 읽어 알려 준다). 해시는 "되돌릴 수 없다" 가 아니라 "입력을 짐작하면 맞출 수 있다" 로 쓴다.
- **2차 수정 (PR 리뷰, 2026-11-24):** 한도 거절이 보고를 반쯤만 쓴 채 끝냈다(원본·기기만 쓰고 사람·부서가 비었다). 쓰기 전에 모든 탭을 계획해 모든 거절을 평가하고, `한도`·팀 행이 거절되면 그 부분만 버리고 사용량은 받는다(원본 거절은 전체 거절). 시간당 한도는 팀원별(`기기` 탭 오른쪽 집계 열)로 세고 공용 풀은 그 시간에 처음 본 팀원만 쓴다. 바뀐 행은 인접한 줄을 한 번의 `setValues` 로 쓴다(`MAX_DAYS` 62 → 21: 앱이 `dayRange 0...20` 으로 최대 21일만 보냄을 v2.5.636~640 에서 확인). 지우기는 일치 행을 `deleteRows` 로 아래부터 지운다(이전엔 탭 전체를 위로 당겨 써서 소유자의 오른쪽 메모 열이 어긋났다). 예산 속성은 바뀔 때만 쓰고 실패해도 요청을 실패시키지 않는다. 총 상한을 낮춰 셀 합이 1000만 셀 앞에서 끝나게 했다. Sheets 가 Date·숫자로 바꾼 날짜·버전 셀은 비교 전에 정규화한다. 새 프로바이더가 들어오는 PR 에서도 허용 목록 테스트가 돌도록 워크플로 경로에 `Local*UsageProvider.swift` 를 더했다. 멤버 홍수용으로 메뉴에 "이 시각 이후 처음 본 멤버 지우기" 를 더했다.
- **2차 왜 못 걸렀나:** 1차 테스트는 정직한 크기와 "원본 상한" 하나만 쏟아 부어서, 다른 탭을 키우는 경로(재전송 키 + 새 팀 ID)와 한도 거절 뒤의 반쯤 쓴 상태를 보지 않았다. 지우기 테스트는 남은 행의 A:F 만 봐서 오른쪽 열이 어긋나는 것을 못 잡았다. 허용 목록 테스트는 있었지만 그 파일을 바꾸는 PR 에서는 워크플로가 돌지 않았다.
- **2차 영구 캡처:** `store.test.js` 의 탭별 거절·반쯤 쓴 상태·팀 행 쏟아붓기·팀원별 상한·공용 풀·예산 속성·셀 합·Date 셀 테스트와 워크플로 경로 테스트, `admin.test.js` 의 메모 열 정렬·묶음 삭제·일괄 지우기 테스트. 가드마다 일부러 되돌려 실패하는 것을 확인했다.
- **2차 규칙:** 거절이 여러 탭에 걸치면 쓰기 전에 모두 평가한다(반쯤 쓴 상태를 남기지 않는다). 상한은 요청 하나가 아니라 "주체별 시간당" 으로도 걸고, 공용 풀은 주체를 구별할 수 없는 쪽에만 물린다. 테스트가 막는 코드가 있는 파일의 경로는 그 테스트를 돌리는 워크플로의 트리거에도 넣는다.
- **3차 수정 (재리뷰, 2026-11-24):** (A) 2차의 쓰기 순서가 기기 행과 예산을 먼저 올리고 데이터 탭을 나중에 써서, 중간에 쓰기가 던지면 안 들어간 행이 이미 팀원 몫과 공용 풀에 청구됐다(재시도가 다음 시간까지 `rate_limited`). 데이터 탭을 먼저 쓰고 기기 행과 예산을 마지막에 올린다. (B) 팀 행이 버려진 날은 앱이 바뀐 날만 다시 보내므로 `부서` 행이 영영 안 생길 수 있었다: 시간마다 도는 `refreshAll` 이 `원본`·`한도` 의 팀 ID 로 빠진 `부서` 행을 채운다(`팀이름` 은 채우지 않음, 문서에 적음). (C) 일괄 지우기 확인 창이 수만 보여 줬다: 가장 이른·늦은 처음 본 시각, ID 앞부분, "앱이 다시 보내지 않아 기록이 영영 사라진다" 를 보이고, 4분이 지나면 온전한 행 단위로 멈춰 다시 실행을 안내한다(기기 탭이 마지막이라 이어 지울 수 있고, 멈춘 실행은 새로 고침하지 않는다).
- **3차 왜 못 걸렀나:** 2차 테스트는 쓰기가 전부 성공하는 경로만 밟았고 "쓰기가 중간에 던진다" 를 주입한 적이 없었다. 팀 행 거절 테스트는 한 번의 보고 안에서만 봤고 "다음 보고에서 다시 오는가" 를 앱의 지문 규칙까지 따라가 보지 않았다.
- **3차 영구 캡처:** `store.test.js` 의 쓰기가 던지는 두 테스트(첫 쓰기·두 번째 탭 쓰기), `admin.test.js` 의 백필·백필 상한·시간 초과 멈춤(일괄·단일)·확인 창 내용 테스트. 가드마다 되돌려 실패하는 것을 확인했다.
- **3차 규칙:** 여러 탭을 쓰는 경로는 청구(카운터·예산)를 쓰기가 모두 끝난 뒤에 올리고, 쓰기가 던지는 테스트를 함께 둔다. 거절로 "버리는" 부분은 다음 보고에서 다시 오는지를 보내는 쪽의 규칙까지 따라가 확인하고, 안 오면 읽는 쪽에서 메운다.

## 안정성 감사(v2.5.640): 놓친 화면 깨움이 스프라이트를 멈추고, 매 폴링이 세이브를 다시 쓰고, 미탐지 셸이 평생 돌았다 (2026-11-24)
- **증상:** ① `screensDidWake` 를 놓치면 `AppDelegate.displayAwake`·`FloatingPetController.displayAwake` 가 false 로 굳어 메뉴바 스프라이트가 멈추고 플로팅 펫이 재기동 전까지 숨는다(#350 은 `UsageStore` 폴링만 고쳤다). 팀 전송도 `willSleep` 만 오고 `didWake` 가 안 오면 광장이 비어 있다. ② `CompanionStore.update()` 가 폴링마다(한 번에 4~10번) 세이브 전체를 다시 인코딩·기록하고 도감을 훑었고, 같은 값 대입으로 `@Observable` 이 매번 발화해 플로팅 펫이 `show()` 를 다시 돌렸다. ③ Codex 가 없는 Mac 은 `BinaryLocator` 의 미탐지 TTL(10분) 때문에 인터랙티브 로그인 셸을 10분마다 평생 띄웠고, 락을 쥔 채 최대 8초 기다렸다. ④ 사탕 창 키가 유일하지 않았다(Gemini 그룹 둘, `limitId` 없는 Codex 버킷): 한 창은 지급하고 다른 창이 tier 를 지워 매 폴링 재지급. ⑤ 다운그레이드한 빌드가 못 읽는 값(알 수 없는 폼·도감 항목)을 관대 디코딩으로 버리고 첫 `update()` 에서 파일을 덮었다. ⑥ `NetworkReachabilityMonitor.onReconnected` 를 메인에서 락 없이 쓰고 모니터 큐에서 락 안에서 읽었다. ⑦ `SpriteVisibleTop` 의 `NSCache` 에 개수 상한이 없었고 키(디코드된 `NSImage`)를 붙들어 두었다.
- **직접 원인:** ① 상태 플래그를 알림 한 쌍이 **유일한 쓰기 경로**로 가졌다. ② `update()` 끝의 무조건 `save()`, 그리고 같은 값을 다시 대입했다. ③ TTL 로 미탐지를 다시 해석했다(결함 로그의 "셸은 프로세스 생애 1회" 규칙과 "락을 쥔 채 외부 프로세스를 기다리지 마라" 규칙을 둘 다 어겼다). ④ 키를 표시 이름의 부분 문자열(`gemini`)·`limitId ?? limitName ?? "codex"` 로 만들어 유일성이 보장되지 않았다. ⑤ 세이브에 형식 버전이 없었다. ⑥·⑦ 잠금·상한이 필드 하나씩 빠졌다.
- **왜 못 걸렀나:** ① 테스트는 `setDisplayAwake(false)` 를 픽스처로만 불렀고 "복구" 경로가 없었다. ② 저장 테스트는 "저장됐나" 만 봤고 "바뀐 게 없을 때 안 쓰는가"·"관찰자가 안 깨는가" 를 안 봤다. ③ 로케이터 테스트는 파서만 시험했다(spawn 횟수를 센 적이 없다). ④ 창 목록 테스트의 픽스처는 그룹이 하나씩이었다. ⑤ 관대 디코딩 테스트는 "깨진 필드를 흡수하는가" 만 봤다. ⑥ 경합은 결정적 테스트가 없다.
- **고침:** ① `AppDelegate.applyState()` 가 `Platform.current.events.displaysAreAsleep` 로 플래그를 맞춘다(`displayAwakeCorrection`). **#350 의 규칙을 그대로 쓴다:** 알림이 재움을 정하고, 재운 지 270초(5분 점검 간격 − 여유)가 지난 낡은 재움만 풀며, 반대로 "깨어 있다는 플래그인데 플랫폼은 잔다" 는 바로 맞춘다. 가상 디스플레이처럼 sleep 을 보고하지 않는 화면이 `screensDidSleep` 직후 플래그를 되돌리지 않는다. 5분 정지 점검이 화면이 켜진 것을 발견하면 `UsageStore.onWakeMissed` 로 같은 맞춤을 부른다. `BonjourTeamTransport` 는 `willSleep` 에서 `sleptAt` 을 적고 60초 벽시계 타이머를 건다: `didWake` 없이도 그 타이머나 그 뒤 첫 reachability 이벤트(`restart()`)가 `begin()` 한다. ② `update()` 는 자기가 바꾸는 장부 필드가 바뀐 때만 `save()` 한다(다른 모든 변경 경로는 자기 `save()` 를 부른다). 어느 경로가 저장을 잊어도 최악이 몇 분이도록 10분 하트비트(`idleSaveInterval`)를 두었고, 종료(Mac `applicationWillTerminate`·Windows `exit`)는 `flush()` 로 무조건 쓴다. `claimedTodayTokensByProvider`·`displayState`·`sulkIdle` 은 값이 다를 때만 대입한다. #358 의 `persistenceBlocked`·`statePlaceholder`·재읽기 의미는 그대로다. ③ 미탐지도 오래 기억한다. 셸로 다시 보는 신호는 앱 재기동, 수동 지정값(`<binary>Path`) 변경, UI 의 수동 새로고침(`UsageStore.refreshByUser` → `BinaryLocator.forgetNotFound`), 마지막 확인 6시간 뒤(`notFoundRecheckInterval`: nvm/fnm 으로 나중에 설치한 도구를 재기동 없이 만난다)뿐이고, 그 사이에는 셸 없는 정적 경로 재확인만 한다. 셸 대기는 락 밖이고, 시간 초과 시 SIGTERM 뒤 `forceKillIfStillRunning` 으로 SIGKILL 한다. ④ `CandyWindow.uniquelyKeyed`: 겹치는 키는 공급자의 고유 id(`bucketId`·`limitId`)가 가장 작은 창이 기존 키를 지키고(저장된 tier 가 맞고, 공급자가 나열하는 순서와 무관) 나머지는 `#<id>`, id 가 없으면 `#<순번>`. 겹치지 않는 창의 키는 그대로다. `evaluateCandyGrants` 는 그래도 겹치는 키를 이번 판정에서 통째로 뺀다. ⑤ `CompanionState.formatVersion`(현재 1)을 `save()` 가 항상 이 빌드의 값으로 쓴다. 로드한 세이브가 **더 새로운** 마커를 달고 있으면 한 번만 `companion-state.newer-<마커>.json` 으로 복사해 두고(있으면 덮지 않음) AppLog 한 줄을 남긴 뒤 **평소처럼** 이어 간다(관대 디코드, 정상 저장). 저장을 막지 않는다: 막으면 구매·부화·토큰이 종료 때마다 사라지고, 가져오기·복원·스냅샷이 "백업 실패" 로 거절된다. 처음 설계한 "읽은 마커와 현재 중 큰 값" 은 이 빌드가 자기 세이브를 더 새롭다고 판정해 영구히 막힐 수 있어 버렸다. 이 버전이 쓴 세이브는 v2.5.640 이 알 수 없는 키(`formatVersion`)를 무시하고 읽는다(디코더가 키드 컨테이너에서 아는 키만 읽음; 알 수 없는 키가 섞인 JSON 을 읽는 테스트). ⑥ `onReconnected` 를 백킹 필드+락 접근자로 바꿨다. ⑦ `SpriteVisibleTop.cache.countLimit = 128`.
- **부류 스윕:** 알림 한 쌍만이 쓰는 상태 플래그: `UsageStore.pollingSuspended`(#350 이 이미 맞춤), 메뉴·펫 두 플래그(이번), Windows 는 `displaysAreAsleep` 를 매번 읽는다. 무조건 `save()` 로 끝나는 주기 경로: `update()` 한 곳. TTL 로 외부 프로세스를 다시 띄우는 곳: `BinaryLocator` 한 곳(`UpdateChecker` 의 brew 도 같은 `resolve` 를 지난다). `NSCache` 개수 상한: 나머지 캐시는 이미 상한이 있다. 락 밖 대입 후 락 안 읽기: `onReconnected` 만(Windows `WindowsReachability` 는 이미 접근자로 잠근다). **의도적으로 남긴 것:** (a) 기도 하루 2번 상한·광장 아이템 칸 기록과 **토큰 장부**는 "날짜가 다르면 처음부터/다시" 규칙이라 시계를 돌리면 다시 받는다 — 소유자가 시계 돌리기를 막지 않기로 해서 `TEAM.md` 큰 나무 줄에 적었다. 토큰 장부는 이번 감사의 항목 4(날짜 키가 뒤로 가면 하루가 다시 적립)였고, 일별 최고 기준값(`dayLedgers`)을 넣었다가 **뺐다**: 공급자를 껐다 켜면(시계를 되돌리고 새로고침) 합계가 다시 적립되는 길이 남았고, 다른 시간대에 보관된 날짜 키로 앞으로 가면 `max(0, 현재 − 보관값)` 만 적립해 정직한 여행자(서울 → 샌프란시스코)가 첫 새로고침의 사용량을 **잃는** 새 경로가 생겼다. 원래 동작(한 번 과다 적립)은 무해해서 main 과 바이트 단위로 같게 되돌렸다. (b) 광장 아이템 칸은 지금 칸 앞뒤(7칸 전 ~ 1칸 뒤)만 기억하므로 시계를 약 40분 넘게 뒤로, 약 2시간 40분 넘게 앞으로 돌렸다 되돌리면 같은 날짜에도 같은 칸을 다시 줍는다. (c) Windows `WindowsTeamTransport` 의 `willSleep` 만 오는 경우는 이번에 고치지 않았다(Mac 이 기준). (d) 가상 디스플레이처럼 `CGDisplayIsAsleep` 이 영영 깨어 있다고 답하는 Mac 에서는 낡은 재움 판정이 5분 뒤 플래그를 되돌린다(#350 폴링과 같은 한계).
- **감사 항목 중 이미 고쳐진 것:** 미래 날짜 스냅샷은 #358 이 `availableSnapshots.first { $0.date <= timestamp }` 로 고쳤다(확인만 함).
- **영구 캡처:** `AuditStabilityTests`(바뀐 게 없으면 쓰지 않음(센티넬 바이트 덮어쓰기로 판정)·날짜 키만 바뀌어도 씀·하트비트·`flush`·같은 값 폴링이 관찰자를 안 깨움·더 새로운 형식은 복사 한 번 + 정상 저장 + 둘째 기동은 복사 안 함·기존 복사본 불변·마커 없는 세이브는 마커를 받음·겹친 키는 지급 없음·id 로 키를 고르고 순서와 무관·겹치지 않는 저장 키는 tier 유지), `AntigravityGroupLocalizationTests.testTwoGeminiGroupsGetDistinctCandyKeys`(실제 `candyEligibleWindows`), `UsageStoreTests.testMissedWakeIsReported…`, `AuditStabilityMacTests`(`displayAwakeCorrection`: 재운 10초 뒤 깨어 있다는 답은 무시·낡은 재움은 풀림·놓친 재움은 바로·`didWake` 없이 reachability/타이머로 전송 복구), `BinaryLocatorTests`(spawn 1회·정적 경로 나중 설치(Windows 는 `.cmd`)는 셸 없이·수동 경로 변경·수동 새로고침·6시간 재확인·락 밖 대기), `NetworkReachabilityTests.testOnReconnectedSurvivesConcurrentSwaps`(가드를 빼면 크래시), `SpriteImageCacheTests.testVisibleTopCacheHasACountLimit`. 가드를 하나씩 일부러 되돌려 해당 테스트가 실패(또는 크래시)하는 것을 확인했다.
- **규칙:** 알림 한 쌍이 유일한 쓰기 경로인 상태는 플랫폼에 직접 묻는 두 번째 경로를 두되, 알림이 정한 상태는 **낡은 것만** 푼다(즉시 덮으면 그 질의가 틀리는 화면에서 알림을 무효로 만든다). 주기 경로의 저장은 "바뀌었나" 를 먼저 보고, 같은 값은 대입하지 않으며(`@Observable`), 잊은 저장을 위한 느린 하트비트와 종료 시 무조건 저장을 함께 둔다. TTL 로 외부 프로세스를 다시 띄우지 마라 — 신호(재기동·설정 변경·사용자의 새로고침)와 긴 주기(6시간)로 다시 본다. **방어를 넣기 전에 정직한 사용자가 잃는 경로가 없는지 본다**(보관값과의 차이만 적립하는 방어는 다른 시간대의 정직한 이동에서 토큰을 잃게 했다). 이름에서 만든 키는 유일성을 구성으로 보장하고 공급자의 고유 id 로 순서와 무관하게 정하며 판정에서도 겹침을 거른다. 새 형식을 읽은 구빌드는 저장을 막지 말고 원본을 한 번 복사해 두고 이어 간다.

## 릴리스·위생 감사(v2.5.640): 지점 브랜치의 실행이 설치본을 댈 수 있었고, 팀 코드 복사가 일반 클립보드에 남았다 (2026-11-24)
- **증상:** ① `team_release.py` 가 Windows 설치본을 낼 실행을 workflow 파일·`workflow_dispatch`·실행 제목(`release <버전> <sha>`)만으로 골랐다. 쓰기 권한이 있는 사람이 자기 브랜치에 "Release pin" 단계를 뺀 `windows-app.yml` 사본을 두고 같은 제목·입력으로 dispatch 하면, 그 사본이 쓴 매니페스트(모든 필드를 만족시킬 수 있다)와 바꿔치기한 설치본이 정직한 릴리스의 `start` 에 "reusing run" 으로 잡혀 `collect`·`publish` 를 통과한다. `workflowSha` 는 40자리 16진수인지만 봤다. ② Mac 의 "코드 복사" 가 `NSPasteboard.general` 에 그냥 써서 유니버설 클립보드·클립보드 관리자 기록에 팀 코드가 남았다(Windows 복사는 이미 제외 표식을 달고 있었다). ③ `ci.yml` 에 `permissions` 가 없었고 `usage-sheet.yml` 은 태그로 액션을 불렀다.
- **직접 원인:** 실행을 "누가 어느 커밋의 workflow 로 돌렸나" 가 아니라 "제목이 맞나" 로 골랐다(제목·입력은 dispatch 하는 사람이 정하는 값이다). 매니페스트는 같은 workflow 가 쓰므로 필드 검사는 workflow 자체가 바뀌면 의미가 없다. 복사는 표식 없는 한 줄이었다.
- **왜 못 걸렀나:** 가짜 GitHub(`FakeGitHub`)의 실행에 `headBranch`·`headSha` 필드가 아예 없었고, 헬퍼도 그 필드를 요청하지 않았다. 그래서 테스트는 "제목이 다른 실행·다른 이벤트" 만 거절하는 경로로 통과했고, 같은 제목의 다른 브랜치 실행이라는 트리거 입력을 만든 적이 없다. 복사에는 테스트가 없었고, Windows 쪽 비밀 복사를 만들 때 Mac 의 같은 동작을 같이 보지 않았다(패리티 목록이 UI 모양만 봤다).
- **고침:** `start` 는 제목이 같아도 `headBranch` 가 이 실행의 ref 가 아니거나 `headSha` 가 릴리스 커밋이 아닌 실행을 이름과 함께 무시하고(리허설이 브랜치에서 만든 실행을 main 릴리스가 재사용하지 못한다) 새로 dispatch 하며, 60초 대기 중 나타난 남의 실행도 집지 않는다. `collect` 는 `runs.json` 의 ref 와 릴리스 커밋을 요구하고 어긋나면 내려받기 전에 멈춘다. 매니페스트 `workflowSha` 는 릴리스 커밋과 같아야 한다. 복사는 `TeamCodePasteboard.write`: `prepareForNewContents(with: .currentHostOnly)` 와 `org.nspasteboard.ConcealedType`·`TransientType`. `ci.yml` 에 `contents: read`, `usage-sheet.yml` 의 두 액션을 SHA 로 고정했다.
- **부류 스윕:** 실행 id 를 고르는 곳은 `start`·`wait_for_new_run`·`collect` 뿐이고 `smoke` 는 제목 없는 실행을 쓰지만 아티팩트·설치본을 만들지 않는다(원 `--ref` 의 smoke workflow 로 읽기 전용 검증). `NSPasteboard` 는 `MacImageClipboard`(사용자가 고른 사진 복사, 비밀 아님)가 하나 더 있다. 태그로 부르는 액션은 `usage-sheet.yml` 의 둘이 남은 전부였다. 윈도 `WinHTTPFetch` 의 407 응답(WPAD 가 고른 프록시에도 로그온 신원으로 답한다)은 이 묶음에서 **고치지 않았다**: WinHTTP 는 한 요청이 WPAD 로 정해졌는지 설정으로 정해졌는지 알려 주지 않고(`WINHTTP_OPTION_PROXY` 는 이름만), 자동 탐지가 켜진 채 PAC 를 쓰는 사내 PC 가 대부분이라 보수적으로 막으면 정직한 사내 프록시가 깨진다. 실제 프록시·WPAD 환경 없이는 안전한 구분을 증명할 수 없어 보류했다.
- **영구 캡처:** `scripts/tests/test_team_release.py` — 다른 브랜치·다른 커밋의 같은 제목 실행을 `start` 가 재사용하지 않음, dispatch 대기 중 심은 남의 실행을 집지 않음, 리허설 브랜치 실행을 main 릴리스가 재사용하지 않음, `collect` 가 다른 브랜치·커밋 실행과 `workflowSha` 불일치를 거절하고 내려받지 않음(가드를 각각 되돌려 실패하는 것 확인). `TeamSettingsTests.testCopiedTeamCodeIsConcealedFromClipboardManagers` — 이름 붙은 개인 pasteboard 로만 검사한다(`.currentHostOnly` 는 읽어서 확인할 수 없어 코드 리뷰와 호출이 근거다).
- **규칙:** 릴리스에 들어가는 산출물을 만든 실행은 제목·입력이 아니라 GitHub 가 기록한 브랜치와 커밋으로 고른다. 가짜 GitHub 는 실제 API 가 주는 신원 필드를 모두 갖고, 테스트는 "같은 모양의 다른 출처" 를 만든다. 비밀을 클립보드에 쓰는 코드는 두 플랫폼에서 같은 표식을 단다.
- **보류 (감사 F3, `Package.resolved` 미커밋):** `originHash` 가 `Package.swift` 의 sha256 이라 `Package.swift` 를 고치기만 해도 커밋된 파일이 낡는다. 의존성이 없는 Mac 에서는 SwiftPM 이 0 핀으로 다시 풀며 추적 중인 파일을 **지우고**, Mac·Windows CI 는 통과한 채 다음 릴리스가 Mac 게이트를 다 돈 뒤 `team-release.sh` 의 "작업 트리가 바뀌었습니다" 에서 멈춘다(모든 Mac 체크아웃도 쓰지 않는 swift-asn1·swift-crypto 를 받는다). Windows 릴리스 빌드는 이미 `build-pins.json` 과 `--only-use-versions-from-resolved-file` 로 버전을 고정한다. 리비전 고정은 Windows 전용 파일(예: Windows 빌드만 복사하는 위치)로 따로 정한다.

## 홈 렌더 테스트 `testQuietDayKeepsHistoricalGraphVisible` 가 UTC 24일부터 CI 에서만 실패했다 (main CI 45299715998, PR #360 CI 45331863373, 2026-11-24, fix/quiet-home-test)
- **증상:** 2026-11-24T00:45Z 이후 `main`·모든 PR 의 맥 CI 가 이 테스트 하나로 실패했다(같은 러너 이미지, 마지막 통과는 11-23T16:05Z, 바뀐 코드는 시트 도구뿐). 내 Mac(KO 로캘, `TZ=UTC` 포함)에서는 통과한다. 업로드된 렌더 PNG 는 정상이었다 — 제품 결함이 아니다.
- **직접 원인(CI 진단으로 확인):** 실패한 단언은 `Missing visible 이번 주`. CI 의 OCR(rev 3, `locale=en_US`, `tz=GMT`, 화면 배율 1.0)은 "이번 주 2.1M" 줄을 "미번 주 2.1M"(신뢰도 0.5, 10개 후보 모두)으로 읽었다. 이번 주 합계는 오늘이 주의 몇 번째 날인지에 따라 달라지는 값이다(화요일 24일 = 일·월 이틀 합 2.1M, 월요일 23일 = "920K"). 같은 줄의 숫자 모양이 바뀌자 이/미 (Vision 이 헷갈리는 글자쌍)가 틀리게 읽혔다. 달 행("이번 달 17.9M")은 같은 렌더에서 신뢰도 1.0 으로 맞게 읽혔다. 처음 세웠던 가설(막대 캡션 동점 규칙)은 틀렸다: 캡션은 `chartVisible=true` 였다.
- **왜 못 걸렀나:** (1) 픽스처가 `Date()` 로 만든 주 합계가 요일마다 다른 문자열로 렌더되는데 테스트는 하루치 날짜만 밟았다. 테스트 안에 "이번→미번" 주석이 이미 있었으나 라벨 비교는 정확 일치였다. (2) 실패 메시지에 한글 OCR 텍스트를 그대로 넣었고, 러너 로그가 비ASCII 를 담은 XCTest 오류 줄을 통째로 버려 `error:` 줄이 로그에 한 줄도 없었다. 그래서 어느 단언인지 두 번의 CI 실패 동안 볼 수 없었다. 같은 일이 다른 OCR 테스트에도 일어난다.
- **부류 스윕:** OCR 로 화면을 읽는 테스트 7개 중 오류 메시지에 OCR 텍스트를 넣는 곳은 이 스위트, `DexColorRenderingTests`(영문 헤더), `CollectionReadabilityRenderingTests`(쪽 표시)였다. 뒤의 둘은 영문 텍스트라 줄이 버려지지 않아 건드리지 않았다. 날짜가 픽스처에 들어가는 렌더 테스트는 이 스위트뿐이다.
- **고침:** 제품 코드는 그대로다. 라벨 비교는 OCR 의 "미번" 을 "이번" 으로 바꾼 텍스트에서 한다(기간 행이 그려졌는지를 보는 단언이지 이/미를 구별하는 단언이 아니다). 이 스위트의 오류 메시지는 `ascii(_:)` 로 비ASCII 를 `\u{..}` 로 바꿔 로그에 남는다. 막대가 그려지는 조건은 OCR 없이 `DailyTrendMetrics.columns` 로 확인하는 단언과 날짜 전 범위 훑기 테스트(`testQuietDayBarsAreDrawnOnEveryCalendarDate`: 2026 년 모든 날 + 2028 윤년 2월, 네 윈도우)로 따로 둔다.
- **영구 캡처:** 위 훑기 테스트(`rollingColumns` 를 일부러 깨면 실패), 그리고 ASCII 안전 메시지 — 다음 OCR 실패는 로그에서 바로 읽힌다.
- **규칙:** 단언 메시지에 OCR·한글 같은 외부 텍스트를 넣을 때는 ASCII 로 이스케이프한다(러너 로그가 비ASCII 오류 줄을 버린다). OCR 단언은 혼동되는 글자쌍을 알고 있는 한 그 쌍을 정규화한 뒤 비교하고, 요일·날짜에 따라 바뀌는 숫자를 라벨과 같은 줄에 그리는 픽스처는 그 값이 바뀌어도 라벨이 읽히는지를 의심한다. 로컬 통과는 CI OCR 의 통과가 아니다: CI 에서 재현되는 실패는 진단 줄(`print`)을 심어 한 번 읽고 지운다.

## 하루 기도 횟수 제한이 기도를 막았다: 기도로 부화하는 것을 제한하라는 뜻이었다 (#349 → fix/prayer-counted-per-day, 2026-11-24)
- **증상:** v2.5.640 에서 알을 하루 3번째 누르면 기도가 세어지지 않고 "오늘 기도는 다 했어요 (하루 2번)" 만 떴다. 소유자의 뜻은 "기도 자체는 무제한, 제한할 것은 기도로 부화하는 것(하루 한 번)" 이었다.
- **직접 원인:** 소유자가 "하루 기도 횟수 제한" 을 요청했고, 구현자(리드)는 대화에서 숫자("하루 2번")만 확인했다. *무엇을 세는지*(기도 횟수인가 기도 부화인가)와 *한도에서 사용자가 무엇을 보는지*(기도가 거절되는가, 알이 기다리는가)를 말하지 않아서 "기도 부화를 제한" 이 "기도를 거절" 로 구현됐다.
- **왜 못 걸렀나:** 테스트는 틀린 요구사항을 충실하게 검증했다(3번째 기도는 세지 않는다, 클릭은 호버 글만 갱신한다). 요구사항이 틀리면 그 위의 테스트는 전부 통과하면서 같은 오해를 굳힌다. 확인 대화에 센 단위와 한도에서의 동작이 없었으니 어떤 리뷰도 대조할 기준이 없었다.
- **부류 스윕:** 코드 패턴이 아니라 절차 부류(한도 요청을 확인 없이 숫자로만 받음)라 grep 대상이 없다. 같은 종류의 기존 한도인 큰 나무 횟수는 TEAM.md 에 센 단위(나무마다)와 한도 뒤 동작(치는 것은 계속 되고 흔들리기만 함)이 적혀 있어 같은 오해 여지가 없는 것을 확인했다.
- **고침:** 기도는 무제한. `isEggReady` 가 "토큰 임계 또는 (기도 10번 이상 그리고 오늘의 기도 부화 미사용)" 을 단일 관문으로 삼고, 기도 부화가 실제로 일어나는 `hatchCore` 에서만 `lastPrayerHatchDay` 를 기록한다(토큰으로 깬 부화는 쓰지 않고, 실패·재시도는 날을 태우지 않는다). 다른 날짜 키는 앞이든 뒤든 새 날이다(나무 규칙과 같고 일부러 막지 않는다). 쓴 날에는 호버 글과 광장 안내가 "오늘은 기도로 이미 부화시켰어요 · 내일 다시 기도로 부화할 수 있어요" 를 보인다.
- **영구 캡처:** `EggPrayerCapTests` 가 열 번이면 즉시 부화, 쓴 날 30번 기도해도 부화하지 않고 횟수 30, 다음 날 새로 고침·기도로 부화, 토큰 부화는 날을 쓰지 않음, 실패한 부화는 날을 태우지 않음, 날짜를 뒤로 돌려도 새 날, v2.5.640 저장 파일 로드를 지킨다. 가드마다 되돌려 실패하는 것을 확인했다.
- **규칙:** 한도를 요청받으면 코드 전에 확인 문구에 세는 단위, 한도에서 일어나는 일, 계속 무제한인 것을 함께 적어 소유자에게 확인받는다. 숫자만 확인하지 않는다.

## 포춘쿠키 쪽지에 "메일 답장이 금방 끝날 거예요" 가 나왔다: 수를 채우려고 운세가 아닌 문구를 넣었다 (2026-11-25 사용자 리포트, feat/fortune-lines-rewrite)
- **증상:** 쪽지에 잡무 예고("메일 답장이 금방 끝날 거예요", "오늘 회의는 일찍 끝날 거예요"), 생활 요령("손을 씻으면 마음도 개운해요"), 개발 용어("캐시를 비우면 길이 보여요"), 광장 이야기("소식판에 좋은 소식이 붙어요")가 나왔다. 포춘쿠키 쪽지로 읽히지 않는다.
- **직접 원인:** #348 이 문구를 80개에서 200개로, 그 뒤 두 줄 문구 100개를 "개수" 를 목표로 늘렸다. 문구가 무엇이어야 하는지는 `PlazaFortune.lines` 주석의 "좋은 말만 쓴다" 한 줄뿐이었다.
- **왜 못 걸렀나:** 문구 테스트는 너비, 중복, 번호 순서만 본다. 내용을 보는 기준도 검토도 없었고, 쓴 사람이 스스로 읽어 통과시켰다. 다시 쓴 첫 초안도 같은 사람이 썼더니 요령·업무 문구가 60개 넘게 남았다: 독립 검토(다른 에이전트)가 세 차례 걸러 냈다.
- **고침:** 300개를 전부 다시 썼다(예전 문구 중 23개만 같은 번호에 남았다). 기준: 좋은 일의 예고, 읽는 사람에 대한 좋은 말, 약속이 되는 속담·격언, 마음·용기·사람·운에 대한 권유. 누구에게나 어느 날에나 맞아야 하고, 지금 형편이 나쁘다고 전제하지 않는다. 속담은 그 자체가 약속일 때만 쓴다(경고·훈계하는 속담은 뺐다).
- **부류 스윕:** 팀 코드에서 15줄이 넘는 글 목록은 이 목록뿐이다(스크립트로 확인). 행운의 행동 12개는 광장에서 할 일이라 그대로 둔다.
- **영구 캡처:** `PlazaFortune.lines` 주석에 기준을 적었다. `PlazaFortuneTests.testNoLineIsAboutAChoreAToolOrTheApp` 이 업무·개발·광장 낱말과 로마자를 막는다(예전 목록에서 88군데 실패하는 것을 확인). 낱말 목록은 같은 부류가 돌아오는 것만 막고 문구의 질은 재지 못한다.
- **호환:** 번호는 그대로 전해지므로 2.5.642 이하의 팀원은 같은 번호에서 그 버전의 문구를 본다. 번호 해시 고정(`testTheFirstLinesAndActionsKeepTheirNumbers`)은 새 300줄 하나로 바꿨다.
- **규칙:** (1) 글 목록은 개수를 목표로 늘리지 않는다: 기준을 먼저 적고, 통과한 것만 넣는다. (2) 사람이 읽는 글(운세, 대사, 안내문)은 쓴 사람이 아닌 독립 검토를 한 번 거친다. (3) 글의 기준은 실제 예(여기서는 진짜 포춘쿠키 쪽지)에서 가져온다.

## 폭탄 돌리기: C로 쳐도 폭탄이 넘어가지 않았다: 맞은 쪽이 늦은 화면으로 "닿았는지"를 다시 쟀다 (2026-11-25 사용자 리포트, fix/bomb-pass-and-holder-speed)
- **증상:** 폭탄을 든 사람이 달아나는 참가자를 따라가 C로 쳤는데(자기 화면에는 충격 그림이 뜬다) 폭탄이 그대로 남는 일이 잦았다.
- **직접 원인:** 폭탄을 넘겨받는 것은 맞은 쪽 Mac이 정하고(`showTackle`), 조건이 "내 화면에서 친 사람의 몸이 내 몸에 닿아 있다"였다. 그런데 두 화면은 늘 조금 어긋난다: 걸음은 출발할 때 도착 칸을 알리므로 방금 출발한 한 칸은 아직 상대에게 가지 않았고(달리기 한 칸 0.075초에 지연이 수십 ms면 걸음의 상당 부분), 상대 그림은 받은 칸을 한 칸씩 뒤따라 걷는다(`PlazaRemoteMotion`, 밀리면 세 칸까지). 친 쪽은 자기 화면의 내 그림에 닿아서 쳤고, 내 화면에서는 그 사람이 한두 칸 뒤에 있다.
- **왜 못 걸렀나:** `testTheHoldersTackleHandsMeTheBomb` 는 둘이 나란히 서 있는 채로 `showTackle` 을 불렀다: 화면이 어긋나는 경우(둘 다 움직이는 중)를 한 번도 밟지 않았다. 문서(TEAM.md)에도 "넘겨받는 것은 맞은 사람의 화면이 정합니다"라고만 적었고, 그 화면이 늦다는 점은 따지지 않았다.
- **고침:** 폭탄은 친 사람이 내 몸에 닿았거나 닿기까지 두 칸(`PlazaBomb.passSlack`: 화면마다 한 칸) 안이면 넘어온다(`PlazaBomb.reaches`, `tackleReachesMe`). 친 사람의 자리는 그려진 칸과 마지막으로 받은 칸을 둘 다 본다. 밀리는 것은 전처럼 내 화면에서 닿았을 때뿐이다. 새 전송 필드는 없다.
- **같이 바꾼 것:** 폭탄을 든 사람은 모든 걸음이 1.5배 빠르다(전에는 뭍에서 달릴 때만 1.2배): 걷기, 달리기, 헤엄(연못·온천), 물에서 나오기. 뛰어드는 걸음(0.36초, 점프 그림과 같은 길이)은 그대로다. 가장 짧은 칸이 0.05초가 되어 `PlazaScene.maxFrameDelta` 를 그 값으로 맞췄다(0.06 → 0.05). `PlazaWalker.isRunning` 은 걸음 길이가 아니라 Shift로 정한다(폭탄을 든 사람의 걷는 칸 0.1초가 달리기로 알려지지 않게).
- **확인하지 못한 다른 후보:** 받는 쪽은 자기 시계로 라운드가 시작됐는지(`t >= roundStartsAt`)와 되돌려주기 금지 2초를 잰다. 두 PC의 시계가 몇 초 어긋나 있으면 라운드 처음 그만큼 넘겨받지 못한다. 팀 PC의 시계 차이를 재 보지 않았고 이 PR은 고치지 않는다.
- **부류 스윕:** 받은 몸통박치기로 밀리는지(`showTackle`), 던진 것에 맞는지(`showSnowball`), 끌려가는지(`showDrag`)도 받는 쪽이 자기 화면의 자리로 다시 잰다: 같은 어긋남이 있어 움직이는 중에는 빗나갈 수 있다. 셋은 밀리거나 끌리는 것뿐이라 판을 바꾸지 않으므로 이 PR에서는 그대로 두었다(고치려면 같은 여유를 두면 된다).
- **영구 캡처:** `PlazaGameControllerTests.testTheHoldersTackleHandsMeTheBombWhenMyScreenShowsThemATileOrTwoShort`(두 칸·세 칸 거리, 밀리지 않음), `testTheHoldersLastToldTileCountsWhenTheDrawingIsBehind`, `testATackleFromFurtherAwayThanTheLagAllowsDoesNotPassTheBomb`, `PlazaGameTests.testTheBombReachesTwoTilesPastTouching`, `testEveryStepOfTheHolderIsHalfAgainAsFastButThePlunge`, `PlazaWalkerTests.testAShortStepWithoutShiftIsNotARun`, `PlazaWindowTests.testASlowFrameWhileRunningReportsEveryTile`(가장 짧은 칸으로 어느 위상에서도 한 프레임에 한 칸). 고치기 전 코드에서 17군데 실패하는 것을 확인했다.
- **규칙:** 다른 Mac이 보낸 "닿았다"를 내 화면으로 다시 잴 때는 두 화면이 어긋나는 만큼을 여유로 둔다. 판정 테스트는 둘 다 서 있는 경우만이 아니라 움직이는 중(내 화면이 늦은 경우)을 밟는다.
