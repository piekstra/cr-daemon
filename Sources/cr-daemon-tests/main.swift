import Foundation

print("cr-daemon-tests\n")

runRateLimitTests()
runConfigTests()
runQueueStoreTests()
runModelsTests()
runSearchParsingTests()
runSupervisorTests()
runReplyThreadTests()
runUpdaterTests()
runFailureClassifyTests()
runTimeoutNoticeTests()
runSchedulerTests()
runRetryRequeueFlagTests()

suite.finish()
