-- Identity, the names newcomers get at random: first names by gender and last names per
-- language (the language of the player; others take en). A list of female last names goes
-- with the list of last names by position; without one the female form is the same.
-- Packages add names with identity:AddNames(language, lists) in their Init on both realms.

local M = NC.Module("identity")

local RU_LAST = {
	"Иванов", "Смирнов", "Кузнецов", "Попов", "Васильев", "Петров", "Соколов", "Михайлов", "Новиков",
	"Фёдоров", "Морозов", "Волков", "Алексеев", "Лебедев", "Семёнов", "Егоров", "Павлов", "Козлов",
	"Степанов", "Николаев", "Орлов", "Андреев", "Макаров", "Никитин", "Захаров", "Зайцев", "Соловьёв",
	"Борисов", "Яковлев", "Григорьев", "Романов", "Воробьёв", "Сергеев", "Фролов", "Александров",
	"Дмитриев", "Королёв", "Гусев", "Киселёв", "Ильин",
}

-- Every one of them ends in -ов, -ев, -ёв or -ин: the female form adds -а.
local RU_LAST_FEMALE = {}
for i, last in ipairs(RU_LAST) do
	RU_LAST_FEMALE[i] = last .. "а"
end

M.NAMES = {
	en = {
		male = {
			"James", "John", "Robert", "Michael", "William", "David", "Richard", "Joseph", "Thomas", "Charles",
			"Daniel", "Matthew", "Anthony", "Mark", "Steven", "Paul", "Andrew", "Joshua", "Kevin", "Brian",
			"George", "Edward", "Ronald", "Timothy", "Jason", "Jeffrey", "Ryan", "Jacob", "Gary", "Nicholas",
			"Eric", "Jonathan", "Stephen", "Larry", "Justin", "Scott", "Frank", "Brandon", "Raymond", "Gregory",
		},
		female = {
			"Mary", "Patricia", "Jennifer", "Linda", "Elizabeth", "Barbara", "Susan", "Jessica", "Sarah", "Karen",
			"Nancy", "Lisa", "Betty", "Margaret", "Sandra", "Ashley", "Emily", "Donna", "Michelle", "Carol",
			"Amanda", "Melissa", "Deborah", "Stephanie", "Rebecca", "Laura", "Sharon", "Cynthia", "Kathleen", "Amy",
			"Shirley", "Angela", "Helen", "Anna", "Brenda", "Pamela", "Nicole", "Emma", "Samantha", "Katherine",
		},
		last = {
			"Smith", "Johnson", "Williams", "Brown", "Jones", "Miller", "Davis", "Wilson", "Anderson", "Taylor",
			"Thomas", "Moore", "Martin", "Jackson", "Thompson", "White", "Harris", "Clark", "Lewis", "Robinson",
			"Walker", "Young", "Allen", "King", "Wright", "Scott", "Hill", "Green", "Adams", "Baker",
			"Nelson", "Carter", "Mitchell", "Roberts", "Turner", "Phillips", "Campbell", "Parker", "Evans", "Edwards",
		},
	},
	ru = {
		male = {
			"Александр", "Алексей", "Андрей", "Антон", "Артём", "Борис", "Вадим", "Валентин", "Василий", "Виктор",
			"Владимир", "Владислав", "Геннадий", "Георгий", "Глеб", "Григорий", "Даниил", "Денис", "Дмитрий",
			"Евгений", "Егор", "Иван", "Игорь", "Илья", "Кирилл", "Константин", "Леонид", "Максим", "Михаил",
			"Никита", "Николай", "Олег", "Павел", "Пётр", "Роман", "Сергей", "Станислав", "Степан", "Тимофей",
			"Юрий",
		},
		female = {
			"Александра", "Алина", "Алла", "Анастасия", "Анна", "Валентина", "Валерия", "Вера", "Виктория",
			"Галина", "Дарья", "Евгения", "Екатерина", "Елена", "Елизавета", "Жанна", "Зоя", "Инна", "Ирина",
			"Карина", "Кира", "Ксения", "Лариса", "Лидия", "Любовь", "Людмила", "Маргарита", "Марина", "Мария",
			"Надежда", "Наталья", "Нина", "Оксана", "Ольга", "Полина", "Светлана", "София", "Татьяна", "Юлия",
			"Яна",
		},
		last = RU_LAST,
		lastFemale = RU_LAST_FEMALE,
	},
}
