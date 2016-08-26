FROM ruby:2.1

RUN apt-get update
RUN apt-get install imagemagick gdal-bin inkscape unzip zip -y
RUN wget https://gist.githubusercontent.com/thejuan/03096b41a8234b27452b85725a92e0f0/raw/d9129be7f91820f300da6f63ac7e3849e1038436/install_phantomjs.sh
RUN bash install_phantomjs.sh

ARG branch=v1.2.1
ARG repo=https://github.com/mholling/nswtopo.git

RUN mkdir -p /usr/src/app
RUN git clone --branch $branch $repo /usr/src/app
RUN mkdir /data
VOLUME /data
WORKDIR /data
ENTRYPOINT ["/usr/src/app/nswtopo.rb"]
