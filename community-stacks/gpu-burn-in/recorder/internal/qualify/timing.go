package qualify

import "time"

// requeueCapture is how long to wait for the report outputs to be captured after the task is
// Healthy. The Platform updates the outputs Secret, not the StackInstance, when it captures them.
const requeueCapture = 30 * time.Second
