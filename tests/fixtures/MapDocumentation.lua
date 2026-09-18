local Map =
{
	Name = "MapUI",
	Type = "System",
	Namespace = "C_Map",
	Environment = "All",

	Functions =
	{
		{
			Name = "GetBestMapForUnit",
			Type = "Function",
			SecretArguments = "AllowedWhenUntainted",
			Documentation = { "Only works for the player and party members." },

			Arguments =
			{
				{ Name = "unitToken", Type = "UnitToken", Nilable = false },
			},

			Returns =
			{
				{ Name = "uiMapID", Type = "number", Nilable = true },
			},
		},
		{
			Name = "ClearUserWaypoint",
			Type = "Function",
		},
		{
			Name = "GoneInThisClient",
			Type = "Function",
			MayReturnNothing = true,
			AddsForbiddenAspects = { { Argument = "self", Aspect = 3 } },

			Arguments =
			{
				{ Name = "mapIDs", Type = "table", InnerType = "number", Nilable = false },
				{ Name = "scale", Type = "number", Nilable = false, Default = 1 },
			},
		},
	},

	Events =
	{
		{
			Name = "MapExplorationUpdated",
			Type = "Event",
			LiteralName = "MAP_EXPLORATION_UPDATED",
			SynchronousEvent = true,
			Payload =
			{
				{ Name = "uiMapID", Type = "number", Nilable = false, ConditionalSecret = true },
			},
		},
	},

	Tables =
	{
		{
			Name = "UIMapType",
			Type = "Enumeration",
			NumValues = 3,
			MinValue = 0,
			MaxValue = 2,
			Fields =
			{
				{ Name = "Cosmic", Type = "UIMapType", EnumValue = 0 },
				{ Name = "World", Type = "UIMapType", EnumValue = 1 },
				{ Name = "Continent", Type = "UIMapType", EnumValue = 2 },
			},
		},
		{
			Name = "UiMapDetails",
			Type = "Structure",
			Fields =
			{
				{ Name = "mapID", Type = "number", Nilable = false },
				{ Name = "name", Type = "cstring", Nilable = false, Documentation = { "Localized \"name\"|with a pipe" } },
				{ Name = "position", Type = "vector2", Mixin = "Vector2DMixin", Nilable = false },
			},
		},
	},

	Predicates =
	{
		{
			Name = "RequiresValidMap",
			Type = "Precondition",
			FailureMode = "ReturnNothing",
		},
	},
};

APIDocumentation:AddDocumentationTable(Map);
