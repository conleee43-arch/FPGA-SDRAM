JedecChain;
	FileRevision(JESD32A);
	DefaultMfr(6E);

	P ActionCode(Cfg)
		Device PartName(EP4CE10) Path("./") File("sdram.jic") MfrSpec(OpMask(1) SEC_Device(EPCS16) Child_OpMask(1 3));

ChainEnd;

AlteraBegin;
	ChainType(JTAG);
AlteraEnd;
