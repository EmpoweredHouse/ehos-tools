Hammox.defmock(EhosPlatform.CommandRunnerMock, for: EhosPlatform.CommandRunner)
Hammox.defmock(EhosPlatform.EnvMock, for: EhosPlatform.Env)
Hammox.defmock(EhosPlatform.ClockMock, for: EhosPlatform.Clock)
Hammox.defmock(EhosPlatform.PublicAddressMock, for: EhosPlatform.PublicAddress)
Hammox.defmock(EhosPlatform.DnsMock, for: EhosPlatform.Dns)
Hammox.defmock(EhosPlatform.CertificateLogMock, for: EhosPlatform.CertificateLog)
# `:node` runs on a k3s node of its own alone (test/node/, the `acme-dns on a node` workflow).
ExUnit.start(exclude: [:node])
