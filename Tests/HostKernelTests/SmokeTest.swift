import Testing
@testable import HostKernel

@Test func kernelVersionIsPopulated() {
    #expect(!HostKernel.version.isEmpty)
}
