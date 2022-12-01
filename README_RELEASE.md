# RELEASE README

First get gemfury setup:

  ```bash
  gem install gemfury
  ```

Put your fury push token into `.fury/api-token` as the only thing in
the file as this is put into an env var via a `cat` command.  To test
you did this right, do:

  ```bash
  export FURY_TOKEN=$(cat .fury/api-token)
  echo $FURY_TOKEN
  ```
And you should get your api-token on a line by itself.


## How to release a gem:

Run the release script:

```bash
ruby release.rb -b develop -v [major|minor|patch|<version-string>]
```

Have a look at the script if you want to understand the required steps.
