(test "Generate rebuilds a letter in a worker after a subject edit"
  (setup (initial-location "/playground/#mode=generate"))
  (steps
    (expect-pending-work "roc-docx/playground/letter" 1)
    (run-effect 1)
    (expect-visible (text "Flour deliveries for the winter"))
    (fill (label "Subject") "A letter built by the signals workflow")
    (expect-pending-work "roc-docx/playground/letter" 1)
    (run-effect 2)
    (expect-visible (text "A letter built by the signals workflow"))
    (expect-visible (role link :name "Download letter.docx"))))
