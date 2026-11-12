(test "Explore reads a sample in a worker and writes an equivalent round trip"
  (setup (initial-location "/playground/#mode=explore&sample=revisions&stage=document"))
  (steps
    (expect-pending-work "roc-docx/playground/model" 1)
    (run-effect 1)
    (expect-visible (text "Supply Agreement Amendment"))
    (click (text "Round trip"))
    (expect-pending-work "roc-docx/playground/round-trip" 1)
    (run-effect 2)
    (expect-visible (role link :name "Download the written document"))
    (expect-attr (test-id "round-trip-verdict") "class" "verdict good")))
