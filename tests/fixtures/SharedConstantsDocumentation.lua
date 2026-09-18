-- A file with no system name: only its Tables survive in APIDocumentation's
-- own lists, so its Predicates are what capture exists to keep.
local SharedConstants =
{
	Tables =
	{
		{
			Name = "AuctionConstants",
			Type = "Constants",
			Values =
			{
				{ Name = "DEFAULT_AUCTION_PRICE_MULTIPLIER", Type = "number", Value = 1.5 },
				{ Name = "LABEL", Type = "string", Value = "line one\nline \"two\" \\ ü" },
			},
		},
	},
	Predicates =
	{
		{
			Name = "SecretWhenSharedThing",
			Type = "Secret",
			Documentation = { "Guarded APIs produce secret values in shared things." },
		},
	},
};

APIDocumentation:AddDocumentationTable(SharedConstants);
