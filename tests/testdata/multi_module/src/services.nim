## Services module that uses models
import std/options
import models

proc getUserById*(users: seq[User]; id: int): Option[User] =
  for user in users:
    if user.id == id:
      return some(user)
  return none(User)

proc getPostsByAuthor*(posts: seq[Post]; authorId: int): seq[Post] =
  result = @[]
  for post in posts:
    if post.authorId == authorId:
      result.add(post)
