USE [LANSA50VCS]
GO
SET IDENTITY_INSERT [X5RUNDTA].[JPNTEST] ON 

INSERT [X5RUNDTA].[JPNTEST] ([Code], [Alpha20], [NChar20], [NVarChar20], [@@UPID], [@@RRNO]) VALUES (N'DUMMY     ', N'たちつてと          ', N'なにぬねの               ', N'はひふへほ', CAST(1 AS Decimal(7, 0)), CAST(1 AS Decimal(15, 0)))
INSERT [X5RUNDTA].[JPNTEST] ([Code], [Alpha20], [NChar20], [NVarChar20], [@@UPID], [@@RRNO]) VALUES (N'TEST      ', N'あいうえお          ', N'かきくけこ               ', N'さしすせそ', CAST(1 AS Decimal(7, 0)), CAST(2 AS Decimal(15, 0)))
SET IDENTITY_INSERT [X5RUNDTA].[JPNTEST] OFF
