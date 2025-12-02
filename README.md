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

