## Data models module

type
  User* = object
    id: int
    username: string
    email: string

  Post* = object
    id: int
    title: string
    content: string
    authorId: int

proc newUser*(id: int, username, email: string): User =
  User(id: id, username: username, email: email)

proc newPost*(id: int; title, content: string; authorId: int): Post =
  Post(id: id, title: title, content: content, authorId: authorId)
