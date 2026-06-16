import Foundation

print("cr-daemon-tests\n")

runRateLimitTests()
runConfigTests()
runQueueStoreTests()
runModelsTests()
runSearchParsingTests()
runSupervisorTests()

suite.finish()
