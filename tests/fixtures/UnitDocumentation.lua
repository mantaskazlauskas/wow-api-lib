local Unit =
{
	Name = "Unit",
	Type = "System",
	Environment = "All",

	Functions =
	{
		{
			Name = "UnitName",
			Type = "Function",
			Arguments = { { Name = "unit", Type = "UnitToken", Nilable = false } },
			Returns =
			{
				{ Name = "name", Type = "cstring", Nilable = false },
				{ Name = "realm", Type = "cstring", Nilable = true },
			},
		},
		{
			Name = "UnitRemovedLongAgo",
			Type = "Function",
		},
	},

	Events =
	{
	},

	Tables =
	{
		{
			Name = "UnitCallback",
			Type = "CallbackType",
			Arguments = { { Name = "unit", Type = "UnitToken", Nilable = false } },
		},
	},
};

APIDocumentation:AddDocumentationTable(Unit);
