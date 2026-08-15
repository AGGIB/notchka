import Testing
@testable import MediaBridge

@Test("delays double starting from one second")
func delaysDouble() {
    var policy = RestartPolicy()
    #expect(policy.nextDelay() == 1)
    #expect(policy.nextDelay() == 2)
    #expect(policy.nextDelay() == 4)
    #expect(policy.nextDelay() == 8)
}

@Test("delay hits the ceiling and stops growing")
func delayIsCapped() {
    var policy = RestartPolicy()
    for _ in 0..<10 { _ = policy.nextDelay() }
    #expect(policy.nextDelay() == 30)
    #expect(policy.nextDelay() == 30)
}

@Test("a successful connection resets the delay")
func successResetsDelay() {
    var policy = RestartPolicy()
    _ = policy.nextDelay()
    _ = policy.nextDelay()
    policy.reset()
    #expect(policy.nextDelay() == 1)
}
