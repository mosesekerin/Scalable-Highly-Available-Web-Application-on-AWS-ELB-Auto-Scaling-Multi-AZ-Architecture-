#  **Scalable & Highly Available Web Application on AWS (ELB + Auto Scaling + Multi-AZ Architecture)**

---

##  **Project Overview**

This project simulates preparing the café’s website for a sudden spike in traffic after being featured on a popular TV food show.
To ensure responsiveness, eliminate single points of failure, and handle fluctuating demand, I built a **scalable, load-balanced, multi-AZ architecture** using AWS services.

The solution distributes traffic across multiple EC2 instances, automatically scales based on workload, and ensures high availability across multiple Availability Zones.

---

##  **Objectives**

This project demonstrates the ability to:

* Inspect and understand VPC network components
* Extend an architecture across multiple Availability Zones
* Deploy an Application Load Balancer (ALB)
* Create a launch template for EC2 instances
* Build an Auto Scaling Group (ASG)
* Configure CloudWatch alarms to trigger scaling
* Test scaling, load distribution, and high availability

---

##  **Architecture**

```
                  Internet
                      │
                Application
              Load Balancer
        ┌──────────┴──────────┐
        │                      │
  Availability Zone A   Availability Zone B
        │                      │
   EC2 Instance          EC2 Instance
 (Auto Scaling Group distributes instances)
        │                      │
        └──────────┬───────────┘
                   VPC
```

**Key Features:**

* Multi-AZ deployment for high availability
* ALB distributes incoming traffic
* Auto Scaling increases or decreases EC2 instances based on demand
* Launch Template standardizes EC2 configuration
* CloudWatch alarms trigger automatic scaling actions

---

##  **AWS Services Used**

* **Amazon EC2**
* **Elastic Load Balancer (Application Load Balancer)**
* **Amazon EC2 Auto Scaling**
* **Amazon VPC** (subnets, route tables, IGW, NACLs)
* **IAM**
* **Amazon CloudWatch**
* **AWS CLI** & Bash scripting (optional)

---

##  **Implementation Steps**

### **1. Inspect Existing VPC**

* Reviewed subnets
* Identified public and private routing
* Validated existing Internet Gateway
* Verified security group rules

### **2. Extend Network Across Multiple AZs**

* Added new subnets in a second Availability Zone
* Updated route tables for proper connectivity
* Ensured subnets were correctly tagged (for ALB + ASG discovery)

### **3. Create Application Load Balancer (ALB)**

* Configured listeners (HTTP :80)
* Created target groups
* Enabled health checks
* Added both subnets (AZ-A and AZ-B) for high availability

### **4. Create Launch Template**

* AMI ID
* Instance type (e.g., t2.micro)
* Key pair
* Security group
* Bootstrapping script (User Data) to install web server:

```
#!/bin/bash
sudo yum install httpd -y
sudo systemctl start httpd
sudo systemctl enable httpd
echo "<h1>Café Web Server - $(hostname)</h1>" > /var/www/html/index.html
```

### **5. Create Auto Scaling Group**

* Minimum capacity: 1
* Desired capacity: 2
* Maximum capacity: 4
* Target group attached for load balancing
* Subnets in both AZs

### **6. Configure CloudWatch Alarms for Auto Scaling**

* Scale out when CPU > 60%
* Scale in when CPU < 20%

### **7. Testing**

* Simulated heavy load using load-testing tools
* Observed ALB distributing traffic
* Verified new EC2 instances starting automatically
* Terminated one instance to test high availability (traffic remained uninterrupted)

---

##  **Repository Structure**

```
/docs
  architecture.png
  scaling-diagram.png

/scripts
  user-data.sh
  load-test.sh

/config
  launch-template.json
  target-group.json

README.md
```

---

##  **Security Considerations**

* Least-privilege IAM role for EC2
* Security group allows HTTP only from ALB
* EC2 instances not exposed directly to public internet
* Only ALB has inbound public access
* No hardcoded credentials in scripts
* NACLs allow minimal required traffic

---

##  **Cost Optimization**

* Only uses Free Tier-eligible EC2 instance types (t2.micro / t3.micro)
* Auto Scaling ensures no over-provisioning
* Instances scale down during low traffic
* Minimal ALB configuration

---

##  **Disaster Recovery / High Availability**

* Multi-AZ infrastructure for failover
* ALB health checks automatically route traffic only to healthy instances
* Replacement of unhealthy EC2 instances via Auto Scaling
* Launch template ensures consistent configuration

---

##  **Testing & Validation**

* Accessed ALB DNS name to confirm load balancing
* Observed instance health checks
* Simulated high CPU load using:

```
sudo stress --cpu 4
```

* Verified Auto Scaling Group launched new instances
* Terminated instances manually to confirm resilience

---

##  **Key Learnings**

* Designing highly available Multi-AZ architectures
* Implementing auto-scaling strategies
* Configuring load balancers in AWS
* Networking and VPC configuration for distributed architectures
* Monitoring and scaling using CloudWatch
* Building self-healing cloud infrastructure

---

##  **Why This Project Matters**

This project demonstrates real cloud engineering skills:

* High availability
* Scalability
* Load balancing
* Network architecture
* Infrastructure automation
* Production-grade architecture design
* Practical AWS knowledge

This is exactly the kind of project hiring managers want to see from cloud engineers.

---

##  **Future Improvements**

* Add CloudFront for global CDN caching
* Add HTTPS using ACM + ALB listener
* Store logs in S3 + CloudTrail
* Convert deployment to Terraform or CloudFormation
* Add CI/CD pipeline

---

##  **Conclusion**

This project showcases my ability to design, deploy, and operate scalable, highly available cloud architectures on AWS using best practices. It demonstrates load balancing, automatic scaling, Multi-AZ architecture design, and real operational readiness for production workloads.

---

