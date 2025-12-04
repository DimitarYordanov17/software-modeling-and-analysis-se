-- Таблица с роли
CREATE TABLE dbo.Roles (
    RoleID      INT IDENTITY(1,1) PRIMARY KEY,
    RoleName    NVARCHAR(50)  NOT NULL,
    Description NVARCHAR(255) NULL
);
GO

-- Потребители (админ, организатор, участник)
CREATE TABLE dbo.Users (
    UserID       INT IDENTITY(1,1) PRIMARY KEY,
    RoleID       INT           NOT NULL,
    Email        NVARCHAR(100) NOT NULL UNIQUE,
    PasswordHash NVARCHAR(200) NOT NULL,
    FirstName    NVARCHAR(50)  NOT NULL,
    LastName     NVARCHAR(50)  NOT NULL,
    CreatedAt    DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    IsActive     BIT           NOT NULL DEFAULT 1,

    CONSTRAINT FK_Users_Roles
        FOREIGN KEY (RoleID) REFERENCES dbo.Roles(RoleID)
);
GO

-- Категории за събития
CREATE TABLE dbo.EventCategories (
    CategoryID  INT IDENTITY(1,1) PRIMARY KEY,
    Name        NVARCHAR(100) NOT NULL,
    Description NVARCHAR(255) NULL
);
GO

-- Локации за събитията
CREATE TABLE dbo.Locations (
    LocationID   INT IDENTITY(1,1) PRIMARY KEY,
    Name         NVARCHAR(100) NOT NULL,
    AddressLine1 NVARCHAR(150) NOT NULL,
    AddressLine2 NVARCHAR(150) NULL,
    City         NVARCHAR(100) NOT NULL,
    Country      NVARCHAR(100) NOT NULL,
    MaxCapacity  INT           NULL
);
GO

-- Таблица за събития
CREATE TABLE dbo.Events (
    EventID         INT IDENTITY(1,1) PRIMARY KEY,
    OrganizerUserID INT           NOT NULL,  -- към Users
    CategoryID      INT           NOT NULL,  -- към EventCategories
    LocationID      INT           NOT NULL,  -- към Locations
    Title           NVARCHAR(150) NOT NULL,
    Description     NVARCHAR(MAX) NULL,
    StartDateTime   DATETIME2     NOT NULL,
    EndDateTime     DATETIME2     NULL,
    Capacity        INT           NOT NULL,
    Price           DECIMAL(10,2) NOT NULL DEFAULT 0,
    IsFree          BIT           NOT NULL DEFAULT 0,
    Status          NVARCHAR(30)  NOT NULL DEFAULT 'Scheduled', -- Scheduled/Cancelled/Completed
    CreatedAt       DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    UpdatedAt       DATETIME2     NULL,

    CONSTRAINT FK_Events_Users
        FOREIGN KEY (OrganizerUserID) REFERENCES dbo.Users(UserID),
    CONSTRAINT FK_Events_Categories
        FOREIGN KEY (CategoryID)      REFERENCES dbo.EventCategories(CategoryID),
    CONSTRAINT FK_Events_Locations
        FOREIGN KEY (LocationID)      REFERENCES dbo.Locations(LocationID)
);
GO

-- Билети
CREATE TABLE dbo.Tickets (
    TicketID          INT IDENTITY(1,1) PRIMARY KEY,
    EventID           INT           NOT NULL,
    UserID            INT           NOT NULL,
    PurchaseDateTime  DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    TicketStatus      NVARCHAR(30)  NOT NULL DEFAULT 'Active',   -- Active/Cancelled/Refunded
    TicketType        NVARCHAR(50)  NOT NULL DEFAULT 'Standard',
    PricePaid         DECIMAL(10,2) NOT NULL,
    UniqueCode        NVARCHAR(100) NOT NULL UNIQUE,

    CONSTRAINT FK_Tickets_Events
        FOREIGN KEY (EventID) REFERENCES dbo.Events(EventID),
    CONSTRAINT FK_Tickets_Users
        FOREIGN KEY (UserID)  REFERENCES dbo.Users(UserID)
);
GO

-- Плащания
CREATE TABLE dbo.Payments (
    PaymentID            INT IDENTITY(1,1) PRIMARY KEY,
    TicketID             INT           NOT NULL,
    Amount               DECIMAL(10,2) NOT NULL,
    Currency             CHAR(3)       NOT NULL DEFAULT 'EUR',
    PaymentDateTime      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
    PaymentMethod        NVARCHAR(50)  NOT NULL,   -- Card, PayPal и т.н.
    PaymentStatus        NVARCHAR(30)  NOT NULL DEFAULT 'Completed',
    TransactionReference NVARCHAR(100) NULL,

    CONSTRAINT FK_Payments_Tickets
        FOREIGN KEY (TicketID) REFERENCES dbo.Tickets(TicketID)
);
GO

-- Функция за свободни места по събитие
CREATE FUNCTION dbo.fn_GetRemainingCapacity (@EventID INT)
RETURNS INT
AS
BEGIN
    DECLARE @capacity INT;
    DECLARE @sold INT;

    SELECT @capacity = Capacity
    FROM dbo.Events
    WHERE EventID = @EventID;

    SELECT @sold = COUNT(*)
    FROM dbo.Tickets
    WHERE EventID = @EventID
      AND TicketStatus = 'Active';

    RETURN ISNULL(@capacity, 0) - ISNULL(@sold, 0);
END;
GO

-- Процедура за продажба на билет (прави Ticket + Payment)
CREATE PROCEDURE dbo.usp_SellTicket
    @EventID       INT,
    @UserID        INT,
    @Price         DECIMAL(10,2),
    @PaymentMethod NVARCHAR(50),
    @Currency      CHAR(3) = 'EUR'
AS
BEGIN
    SET NOCOUNT ON;

    -- Проверка дали има места
    IF dbo.fn_GetRemainingCapacity(@EventID) <= 0
    BEGIN
        RAISERROR('Event is full.', 16, 1);
        RETURN;
    END;

    DECLARE @TicketID INT;

    INSERT INTO dbo.Tickets
        (EventID, UserID, PurchaseDateTime, TicketStatus, TicketType, PricePaid, UniqueCode)
    VALUES
        (@EventID, @UserID, SYSUTCDATETIME(), 'Active', 'Standard', @Price, CONVERT(NVARCHAR(100), NEWID()));

    SET @TicketID = SCOPE_IDENTITY();

    INSERT INTO dbo.Payments
        (TicketID, Amount, Currency, PaymentDateTime, PaymentMethod, PaymentStatus, TransactionReference)
    VALUES
        (@TicketID, @Price, @Currency, SYSUTCDATETIME(), @PaymentMethod, 'Completed', CONVERT(NVARCHAR(100), NEWID()));
END;
GO

-- Тригер за капацитет – не дава да мине, ако се препълни
CREATE TRIGGER dbo.trg_Tickets_CheckCapacity
ON dbo.Tickets
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    -- Ако след insert капацитетът стане под 0 -> връщаме транзакцията
    IF EXISTS (
        SELECT 1
        FROM inserted i
        CROSS APPLY (SELECT dbo.fn_GetRemainingCapacity(i.EventID) AS Remaining) r
        WHERE r.Remaining < 0
    )
    BEGIN
        RAISERROR('Event capacity exceeded.', 16, 1);
        ROLLBACK TRANSACTION;
    END
END;
GO

-- Примерни данни

-- Роли
INSERT INTO dbo.Roles (RoleName, Description)
VALUES ('Admin',      N'Системен администратор'),
       ('Organizer',  N'Организатор на събития'),
       ('Participant',N'Обикновен потребител');
GO

-- Потребители
INSERT INTO dbo.Users (RoleID, Email, PasswordHash, FirstName, LastName)
VALUES (1, 'admin@example.com',     'hash-admin', 'Admin',  'User'),
       (2, 'organizer@example.com', 'hash-org',   'Olivia', 'Organizer'),
       (3, 'user1@example.com',     'hash-u1',    'Peter',  'Participant'),
       (3, 'user2@example.com',     'hash-u2',    'Maria',  'Participant');
GO

-- Категории (основни)
INSERT INTO dbo.EventCategories (Name, Description)
VALUES (N'Conference', N'Професионални конференции'),
       (N'Concert',    N'Музикални събития'),
       (N'Workshop',   N'Обучителни уъркшопи');
GO

-- Локации
INSERT INTO dbo.Locations (Name, AddressLine1, City, Country, MaxCapacity)
VALUES (N'Hall A',        N'Main Street 1',  N'Sofia',   N'Bulgaria', 200),
       (N'Open Air Park', N'Central Park',   N'Plovdiv', N'Bulgaria', 500);
GO

-- Примерни събития
INSERT INTO dbo.Events
    (OrganizerUserID, CategoryID, LocationID, Title, Description,
     StartDateTime, EndDateTime, Capacity, Price, IsFree)
VALUES
    (2, 1, 1,
     N'Tech Conference 2025', N'IT и стартъпи',
     '2025-12-10T10:00:00', '2025-12-10T18:00:00', 150, 120.00, 0),

    (2, 2, 2,
     N'Rock Concert Night', N'Жива рок музика',
     '2025-12-20T20:00:00', '2025-12-20T23:30:00', 400, 50.00, 0);
GO

-- Примерни продажби за тест
EXEC dbo.usp_SellTicket @EventID = 1, @UserID = 3, @Price = 120.00, @PaymentMethod = N'Card';
EXEC dbo.usp_SellTicket @EventID = 1, @UserID = 4, @Price = 120.00, @PaymentMethod = N'PayPal';
EXEC dbo.usp_SellTicket @EventID = 2, @UserID = 3, @Price = 50.00,  @PaymentMethod = N'Card';
GO

-- Допълнителни данни за Power BI тест

-- още категории
INSERT INTO EventCategories (Name, Description)
VALUES ('Music', 'Concerts and music events'),
       ('Tech', 'Tech conferences and meetups'),
       ('Sport', 'Sports events and competitions');

-- още локации
INSERT INTO Locations (Name, AddressLine1, City, Country, MaxCapacity)
VALUES ('Plovdiv Arena', 'Ul. Sportna 15', 'Plovdiv', 'Bulgaria', 5000),
       ('Sofia Expo Center', 'Tzarigradsko shose 147', 'Sofia', 'Bulgaria', 3000),
       ('Varna Congress Hall', 'Primorski Blvd 20', 'Varna', 'Bulgaria', 1200);

-- още организатори
INSERT INTO Users (RoleID, Email, PasswordHash, FirstName, LastName, CreatedAt, IsActive)
VALUES (1, 'org1@example.com', 'hash', 'Ivan', 'Petrov', GETDATE(), 1),
       (1, 'org2@example.com', 'hash', 'Maria', 'Ivanova', GETDATE(), 1),
       (1, 'org3@example.com', 'hash', 'Stoyan', 'Dimitrov', GETDATE(), 1);

-- още събития за различни градове/категории
INSERT INTO Events 
(OrganizerUserID, CategoryID, LocationID, Title, Description, StartDateTime, Capacity, Price, IsFree, Status, CreatedAt)
VALUES
(1, 1, 1, 'Rock Night Plovdiv', 'Big live concert', GETDATE(), 800, 40.00, 0, 'Active', GETDATE()),
(2, 2, 2, 'TechConf Sofia', 'Technology meeting', GETDATE(), 400, 60.00, 0, 'Active', GETDATE()),
(3, 3, 3, 'Varna Marathon', 'Sports running event', GETDATE(), 2000, 20.00, 0, 'Active', GETDATE());

-- билети за тези събития
INSERT INTO Tickets (EventID, UserID, PurchaseDateTime, TicketStatus, TicketType, PricePaid, UniqueCode)
VALUES
-- Rock Night Plovdiv (EventID 1)
(1, 1, GETDATE(), 'Active', 'Standard', 40.00, 'ROCK001'),
(1, 1, GETDATE(), 'Active', 'Standard', 40.00, 'ROCK002'),
(1, 2, GETDATE(), 'Active', 'VIP',      80.00, 'ROCK003'),

-- TechConf Sofia (EventID 2)
(2, 2, GETDATE(), 'Active', 'Standard', 60.00, 'TECH001'),
(2, 3, GETDATE(), 'Active', 'VIP',      120.00, 'TECH002'),

-- Varna Marathon (EventID 3)
(3, 1, GETDATE(), 'Active', 'Standard', 20.00, 'RUN001'),
(3, 2, GETDATE(), 'Active', 'Standard', 20.00, 'RUN002'),
(3, 3, GETDATE(), 'Active', 'Standard', 20.00, 'RUN003'),
(3, 3, GETDATE(), 'Active', 'VIP',      50.00, 'RUN004');

-- плащания
INSERT INTO Payments (TicketID, Amount, Currency, PaymentDateTime, PaymentMethod, PaymentStatus)
VALUES
-- Rock Night
(1, 40.00, 'BGN', GETDATE(), 'Card', 'Paid'),
(2, 40.00, 'BGN', GETDATE(), 'Card', 'Paid'),
(3, 80.00, 'BGN', GETDATE(), 'Cash', 'Paid'),

-- TechConf Sofia
(4, 60.00, 'BGN', GETDATE(), 'Card', 'Paid'),
(5, 120.00, 'BGN', GETDATE(), 'Card', 'Paid'),

-- Varna Marathon
(6, 20.00, 'BGN', GETDATE(), 'Cash', 'Paid'),
(7, 20.00, 'BGN', GETDATE(), 'Card', 'Paid'),
(8, 20.00, 'BGN', GETDATE(), 'Card', 'Paid'),
(9, 50.00, 'BGN', GETDATE(), 'Card', 'Paid');

