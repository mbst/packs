FROM fedora:24

LABEL maintainer "grrywlsn"
# Based on packs image resizer, as forked here: https://github.com/mbst/packs

RUN dnf -y update && dnf clean all
RUN dnf -y install redhat-rpm-config tcl-devel libpng-devel libjpeg-devel ghostscript-devel bzip2-devel freetype-devel libtiff-devel libpng12-devel.i686 GraphicsMagick ImageMagick ImageMagick-devel rubygems rubygem-rails ruby-devel libxml2-devel gcc gcc-c++ make automake && \
    dnf clean all

RUN mkdir -p /app
WORKDIR /app
ADD . /app
RUN gem install therubyracer -v '0.12.3'
RUN bundle install

EXPOSE 9292
CMD ["bundle", "exec", "rackup", "--env", "production", "--host", "0.0.0.0", "-p", "9292"]
