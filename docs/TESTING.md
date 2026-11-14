# Testing and coverage

## Automated offline checks

`./test.sh` generates its own build-only configuration from the tracked synthetic example, independently of any personal configuration.

- Configuration validation: supported conversation routes, host/scheme/credential restrictions, query/fragment rejection and consistent Swift/JavaScript generation.
- Swift model/backend fixtures: cache bounds and hits, cancellation, stale result/partial suppression, error handling, serialization, draft preservation, Instant selection, uncertain-submission protection and successful explicit requests after a lost response document.
- JavaScript DOM fixtures: conversation isolation, visible/ambiguous controls, exact in-memory paste, fallback insertion, changed draft refusal, idempotent jobs, matching responses, owned Stop checks, completion races, persistent ownership after a new document context, changed-document zero-send guards and no automatic replay of lost jobs.
- Selection fixtures: global settings persistence, exclusions, selected-range extraction, stale/ambiguous pane rejection, secure controls, foreign processes, ordinary clicks, coordinate conversion and OCR line ordering.

These tests do not open/control Safari, launch the app, capture a screen, register global shortcuts or alter the installed app's permissions. Test defaults use temporary named domains that are removed afterward. `./test.sh --vision-check` additionally recognizes generated text and a blank image entirely in memory; it makes no screen capture or network request.

## Prior live validation of the 0.2.3 implementation

Before this public export, the application was exercised with synthetic content in disposable Safari windows. The observed regression was a stored tab position becoming stale after another tab was inserted or removed. Live tests covered shifts in both directions, real reload, navigation away, closed tabs, closed windows and a translation after an intentional index shift. Existing window IDs and tab counts were checked for preservation.

Safari restart detection was tested by simulating a process-ID change. Safari was not actually quit because that would affect existing user windows. Losing a response page during an active GPT generation is covered by fixtures rather than claimed as a live-browser pass. Those local browser-control harnesses and their runtime records are intentionally excluded from this public repository.

## What the offline suite does not establish

Passing fixtures does not guarantee compatibility with every macOS app or future ChatGPT UI. Physical mouse selection, real permission prompts, multi-display capture, website login/session behavior and actual GPT latency need manual testing on the intended Mac. The public configuration/build adaptation is verified offline; the publication process does not reinstall or retest the user's working app.

No percentile or one-second fresh-output guarantee is claimed. Run live tests only against clearly synthetic content in a dedicated conversation/window, preserve user drafts, and never resend an uncertain submission automatically.
