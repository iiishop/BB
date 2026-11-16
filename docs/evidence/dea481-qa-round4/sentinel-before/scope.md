Candidate 35c9223f45613e916c9d6d5f90d510feba3f713d; requirements unchanged. Reuse prior qa/scope.md inventory, not its outcome.

Changed paths: compose controller baseline/request snapshot/upload reconciliation; controller/detail reference invalidation; supporting helper/tests. Independent review focus:
1. Original three probes and additional developer image-remove, dirty-text-upload, upload/external-writer counterexamples.
2. Upload successful receipt then failed confirmation read then retry, with nonempty local image edits. Preserve both receipt version and original local image intent; same/equal versions must accept legitimate changes, advanced external versions must conflict.
3. All reference snapshot writers: event scrub, initial/refresh feed replacement, pagination append, pending page application, detail load/reload. A response captured before deletion must not restore deleted text after invalidation.
4. Dirty draft recovery: server identical-to-local state should be accepted; actual changed remote base should conflict. Explicit reload should remain usable.
5. Retain baseline source and test/lock equivalence for unchanged server/plugin evidence. Do not repeat unrelated full tests. Device/native/model acceptance remains separate and incomplete until supported by evidence.

No production edits. Run new reachable counterexamples against real FastAPI, using gateway wrappers only to delay accepted responses or fail confirmation reads. New probes remain outside default CI until repaired.
