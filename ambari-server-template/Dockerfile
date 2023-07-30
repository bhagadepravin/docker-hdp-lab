FROM centos:7

RUN yum install openssh-server epel-release -y 
RUN yum install openssh-clients -y
RUN mkdir /root/.ssh
RUN touch /root/.ssh/authorized_keys
RUN chmod 700 /root/.ssh
RUN chmod 400 /root/.ssh/authorized_keys
ADD id_rsa /root/.ssh/
ADD id_rsa.pub /root/.ssh/
RUN echo "hadoop" | passwd --stdin root
RUN chkconfig sshd on
ADD ambari.repo /etc/yum.repos.d/
RUN yum install ambari-agent -y
RUN yum install ambari-server -y
RUN mv /var/lib/ambari-server/resources/views/ambari-views-package-2.7.6.0.0.jar /var/lib/ambari-server/resources/views/ambari-views-package-2.7.6.0.0.jar_bk
RUN ambari-server setup -s
RUN mv /var/lib/ambari-server/resources/views/ambari-views-package-2.7.6.0.0.jar_bk /var/lib/ambari-server/resources/views/ambari-views-package-2.7.6.0.0.jar
ADD ./start /
CMD ["/start"]
