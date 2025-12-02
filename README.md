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

![Architectural Diagram](/architecture/final-architecture.png)
---

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

### *1. Environment Inspection*

Before modifying the architecture, I inspected the existing VPC setup to understand the current state of the café’s infrastructure.

Key activities included:

* Reviewing the VPC, subnets, route tables, and IGW configuration
* Analyzing the *CafeSG* security group and identifying open ports
* Verifying public/private subnet placement and their internet accessibility
* Confirming whether instances in Private Subnet 1 and 2 should reach the internet
* Checking if the existing *CafeWebAppServer* instance was publicly reachable
* Identifying the AMI created during lab setup ( Cafe WebServer Image )

This inspection step helped validate assumptions and ensured readiness for a multi-AZ deployment.

---

### *2. Updating the Network for Multi-AZ High Availability*

#### *2.1 Create a NAT Gateway in the Second Availability Zone*

To support EC2 instances in *Private Subnet 2* and enable outbound internet access:

* Created a *NAT Gateway* in the public subnet of the second Availability Zone
* Allocated an Elastic IP for the NAT Gateway
* Updated route tables so that Private Subnet 2 routes 0.0.0.0/0 traffic to this new NAT Gateway

This ensured instances deployed across multiple AZs have consistent outbound internet access for updates, patching, and metadata retrieval.

---

### *3. Creating a Launch Template*

Using the AMI generated from the *CafeWebAppServer*, I created a standardized launch template for Auto Scaling.

Launch template configuration:

* *AMI: *Cafe WebServer Image (from My AMIs)
* *Instance Type*: t2.micro
* *Key Pair*: Newly generated and downloaded for SSH access
* *Security Group*: CafeSG
* *Tags*:

  * Key: Name
  * Value: webserver
  * Resource Type: Instances
* *IAM Instance Profile*: CafeRole (required for session manager and metadata access)

This template serves as the blueprint for all future EC2 instances launched by the Auto Scaling group.

---

### *4. Creating an Auto Scaling Group*

Next, I created an Auto Scaling Group (ASG) using the launch template.

Configuration:

* *ASG Name*: (custom name)
* *VPC*: The existing lab VPC
* *Subnets*: Private Subnet 1 and Private Subnet 2
* *Desired Capacity*: 2
* *Minimum Capacity*: 2
* *Maximum Capacity*: 6
* *Scaling Policy: *Target Tracking Scaling Policy

  * Metric: *Average CPU Utilization*
  * Target Value: 25%
  * Instance Warmup: 60 seconds

To verify accuracy, I checked the EC2 console to confirm two running instances tagged “webserver”.

---

### *5. Creating an Application Load Balancer*

To expose the web app to the internet and distribute incoming traffic evenly:

* Created an *Application Load Balancer (ALB)*
* *Subnets*: Both public subnets (Multi-AZ for HA)
* *Security Group*: New SG allowing HTTP (port 80) from anywhere
* *Target Group: Created a new target group but did *not register targets initially

After ALB activation:

* Modified the Auto Scaling Group to attach the new *target group*
* Ensured new instances automatically register with the ALB

This allowed public users to access the private EC2 instances via the ALB endpoint.

---

### *6. Testing Load Balancing & Auto Scaling*

#### *6.1 Functional Test (Without Load)*

* Accessed the ALB DNS name
* Appended /cafe to load the café application
* If issues occurred, validated:

  * NAT configuration
  * Route tables
  * IAM role on launch template
  * ALB in public subnets
  * Auto Scaling deployment correctness
  * Security group configurations

#### *6.2 Load Test (Automatic Scaling Validation)*

Using *AWS Systems Manager Session Manager*, I connected to one webserver instance and ran a CPU stress test:

```
sudo amazon-linux-extras install epel
sudo yum install stress -y
stress --cpu 1 --timeout 600
```

During the test:

* CloudWatch detected increased CPU utilization
* Auto Scaling automatically launched additional EC2 instances
* ALB distributed incoming traffic across the new instances
* The system demonstrated graceful scaling under load

---

##  **Repository Structure**

```
aws-ha-webapp-project/
 ├── README.md
 ├── architecture/
 │     └── diagram.png
 ├── infra/
 │     ├── setup-infra.sh
 │     ├── create-alb.sh
 │     ├── create-asg.sh
 │     └── cleanup.sh
 ├── scripts/
 │     ├── user-data.sh
 │     ├── stress-test.sh
 │     └── check-alb-health.sh
 └── app/
       └── index.html (optional)
```

---

#  **Security Considerations**

This architecture applies several layers of security to protect infrastructure and application traffic:

* **Least Privilege IAM Roles**:
  The EC2 instances use an IAM role (`CafeRole`) that grants only the required permissions (e.g., SSM access). No root or unnecessary privileges.

* **Security Groups as Virtual Firewalls**:

  * The ALB security group only allows inbound HTTP (port 80) from the internet.
  * The webserver security group only allows traffic **from the ALB**, not the entire world.
  * Outbound access is restricted to essentials.

* **Private Subnets for EC2 Instances**:
  Application servers run in **private subnets**, removing direct exposure to the internet.

* **Controlled Internet Access via NAT Gateways**:
  Instances get outbound internet access for updates while remaining non-public.

* **Multi-AZ ALB**:
  Ensures end-users access the app without reaching private instances directly.

* **Patching & Updates**:
  By ensuring outbound access through NAT, instances can receive OS and package updates to reduce vulnerabilities.

* **Monitoring & Alerting**:
  CloudWatch metrics and logs enable visibility into abnormal activities or potential security issues.

---

#  **Cost Optimization**

Several decisions in this architecture reduce operational costs:

* **Auto Scaling**:
  Capacity automatically increases during high traffic and scales down when demand drops, preventing over-provisioning.

* **Small Instance Types (t2.micro)**:
  Ideal for lightweight workloads, testing, and learning environments.

* **AMI-Based Launch Template**:
  AMIs reduce boot time and avoid unnecessary provisioning actions.

* **Right-Sized NAT Gateways**:
  While NAT Gateways incur cost, placing one in each AZ ensures reliability.
  In production, NAT Gateway usage can be optimized by:

  * Reducing cross-AZ routing
  * Aggregating traffic patterns
  * Using instance-based NAT for non-critical workloads

* **Load Balancer Health Checks**:
  Reduce costs by ensuring only healthy instances stay in rotation, avoiding wasted compute cycles.

* **Use of SSM for Access**:
  Removes the need for public IPs or bastion hosts, reducing additional infrastructure costs.

---

# ��️ **Disaster Recovery / High Availability**

This project implements a strong foundation for DR and HA:

* **Multi-AZ Deployment**:

  * ALB deployed across two public subnets
  * Auto Scaling Group deployed across two private subnets
    Meaning your application stays online even if one AZ goes down.

* **Health Checks & Auto Healing**:

  * ALB removes unhealthy targets automatically
  * ASG replaces failed instances without manual intervention

* **Immutable AMI Architecture**:
  Re-creating instances from AMIs ensures consistent recovery.

* **Stateless Web Tier**:
  Allows Auto Scaling to scale or replace instances without losing application state.

* **Route Table Redundancy**:
  NAT Gateways in each AZ guarantee AWS best-practice failover.

This setup achieves resilience at the compute, networking, and load-balancing layers.

---

#  **Key Learnings**

From this project, the following cloud engineering concepts were reinforced:

* How to deploy **highly available architectures across multiple AZs**
* Understanding **private vs public subnets** and their routing patterns
* Implementing **NAT Gateways** for controlled internet access
* Building **Launch Templates** and **Auto Scaling Groups**
* Deploying an **Application Load Balancer** and integrating it with ASG
* Using **IAM Roles**, **SSM**, and **security groups** effectively
* Running stress tests to validate **scaling behavior**
* Observing how AWS handles **elasticity**, **fault tolerance**, and **health checks**

---

#  **Why This Project Matters**

This project demonstrates real-world skills expected from a Cloud/DevOps Engineer:

* You architected a **production-style** web application infrastructure.
* You showcased **hands-on expertise** using core AWS services.
* You proved you understand **high availability**, **scaling**, and **cloud-native security**.
* You validated performance using **CPU stress testing**, similar to load testing in real deployments.
* The architecture matches what is used by real companies running public-facing workloads.

This is the type of project that **impresses recruiters** because it shows you can build, optimize, and secure infrastructure end-to-end.

---

#  **Future Improvements**

To strengthen the solution and bring it closer to enterprise-grade:

### **Infrastructure**

* Add **Infrastructure as Code (IaC)** using Terraform or AWS CloudFormation
* Replace `t2.micro` with **T-series Unlimited** for smoother scaling
* Introduce **AWS WAF** for layer-7 protection

### **Application Layer**

* Containerize the web app using **Docker**
* Deploy to **ECS Fargate** behind the ALB

### **Security**

* Add **AWS Secrets Manager** for credential management
* Implement **VPC Flow Logs** for traffic visibility
* Add **GuardDuty** + **Security Hub** for threat detection

### **Data Layer**

* Introduce **RDS Multi-AZ** or DynamoDB for persistent storage
* Add **S3 + CloudFront** for static asset distribution

### **Observability**

* Add detailed CloudWatch dashboards
* Implement Alarms for:

  * High error rate
  * High latency
  * Scaling failures

### **Resilience**

* Implement **blue/green deployments**
* Add **AWS Backup** policies
* Introduce **cross-region** failover using Route 53

---

##  **Conclusion**

This project showcases my ability to design, deploy, and operate scalable, highly available cloud architectures on AWS using best practices. It demonstrates load balancing, automatic scaling, Multi-AZ architecture design, and real operational readiness for production workloads.

---

